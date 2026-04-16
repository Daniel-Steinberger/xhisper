#!/bin/bash

# xhisper v1.0
# Dictate anywhere in Linux. Transcription at your cursor.
# - Transcription via Groq Whisper

# Configuration (see default_xhisperrc or ~/.config/xhisper/xhisperrc):
# - long-recording-threshold : threshold for using large vs turbo model (seconds)
# - transcription-prompt : context words for better Whisper accuracy
# - language : ISO 639-1 code (e.g. "de", "en"); empty = auto
# - paste-mode : auto | type | clipboard | clipboard-restore
# - placeholders : auto | inline | notify | off
# - placeholder-recording / placeholder-transcribing / placeholder-silent : status strings
# - silence-threshold : max volume in dB to consider silent (e.g., -50)
# - silence-percentage : percentage of recording that must be silent (e.g., 95)
# - non-ascii-initial-delay : sleep after first non-ASCII paste (seconds)
# - non-ascii-default-delay : sleep after subsequent non-ASCII pastes (seconds)
# - paste-clipboard-delay : sleep between wl-copy and Ctrl+V (seconds)

# Requirements:
# - pipewire, pipewire-utils (audio)
# - wl-clipboard (Wayland) or xclip (X11) for clipboard
# - jq, curl, ffmpeg (processing)
# - make to build, sudo make install to install

[ -f "$HOME/.env" ] && source "$HOME/.env"

# Parse command-line arguments
LOCAL_MODE=0
WRAP_KEY=""
for arg in "$@"; do
  case "$arg" in
    --local)
      LOCAL_MODE=1
      ;;
    --log)
      if [ -f "/tmp/xhisper.log" ]; then
        cat /tmp/xhisper.log
      else
        echo "No log file found at /tmp/xhisper.log" >&2
      fi
      exit 0
      ;;
    --leftalt|--rightalt|--leftctrl|--rightctrl|--leftshift|--rightshift|--super)
      if [ -n "$WRAP_KEY" ]; then
        echo "Error: Multiple wrap keys not yet supported" >&2
        exit 1
      fi
      WRAP_KEY="${arg#--}"
      ;;
    *)
      echo "Error: Unknown option '$arg'" >&2
      echo "Usage: xhisper [--local] [--log] [--leftalt|--rightalt|--leftctrl|--rightctrl|--leftshift|--rightshift|--super]" >&2
      exit 1
      ;;
  esac
done

# Set binary paths based on local mode
if [ "$LOCAL_MODE" -eq 1 ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  XHISPERTOOL="$SCRIPT_DIR/xhispertool"
  XHISPERTOOLD="$SCRIPT_DIR/xhispertoold"
else
  XHISPERTOOL="xhispertool"
  XHISPERTOOLD="xhispertoold"
fi

RECORDING="/tmp/xhisper.wav"
LOGFILE="/tmp/xhisper.log"
PROCESS_PATTERN="pw-record.*$RECORDING"

log() {
  local ts
  ts=$(date '+%H:%M:%S.%N')
  ts="${ts:0:12}"  # HH:MM:SS.mmm — truncate to milliseconds
  printf '[%s] [pid=%d] %s\n' "$ts" $$ "$*" >> "$LOGFILE"
}

dlog() {
  [ "$debug_log" = "true" ] && log "$@"
}

# Default configuration
long_recording_threshold=1000
transcription_prompt=""
language=""
paste_mode="auto"
placeholders="auto"
silence_threshold=-50
silence_percentage=95
non_ascii_initial_delay=0.1
non_ascii_default_delay=0.025
paste_clipboard_delay=0.15
placeholder_recording="🎤"
placeholder_transcribing="⏳"
placeholder_silent="🔇 no sound"
debug_log=false

CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/xhisper/xhisperrc"

if [ -f "$CONFIG_FILE" ]; then
  while IFS=: read -r key value || [ -n "$key" ]; do
    # Skip comments and empty lines
    [[ "$key" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$key" ]] && continue

    # Trim whitespace, strip inline "# comment", strip surrounding quotes
    key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    value=$(echo "$value" | sed 's/[[:space:]]#.*$//;s/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//')

    case "$key" in
      long-recording-threshold) long_recording_threshold="$value" ;;
      transcription-prompt) transcription_prompt="$value" ;;
      language) language="$value" ;;
      paste-mode) paste_mode="$value" ;;
      placeholders) placeholders="$value" ;;
      silence-threshold) silence_threshold="$value" ;;
      silence-percentage) silence_percentage="$value" ;;
      non-ascii-initial-delay) non_ascii_initial_delay="$value" ;;
      non-ascii-default-delay) non_ascii_default_delay="$value" ;;
      paste-clipboard-delay) paste_clipboard_delay="$value" ;;
      placeholder-recording) placeholder_recording="$value" ;;
      placeholder-transcribing) placeholder_transcribing="$value" ;;
      placeholder-silent) placeholder_silent="$value" ;;
      debug-log) debug_log="$value" ;;
    esac
  done < "$CONFIG_FILE"
fi

# Auto-start daemon if not running
if ! pgrep -x xhispertoold > /dev/null; then
    if [ "$debug_log" = "true" ]; then
      XHISPER_DEBUG=1 "$XHISPERTOOLD" 2>> /tmp/xhispertoold.log &
    else
      "$XHISPERTOOLD" 2>> /tmp/xhispertoold.log &
    fi
    sleep 1  # Give daemon time to start

    # Verify daemon started successfully
    if ! pgrep -x xhispertoold > /dev/null; then
        echo "Error: Failed to start xhispertoold daemon" >&2
        echo "Check /tmp/xhispertoold.log for details" >&2
        exit 1
    fi
fi

# Check if xhispertool is available
if ! command -v "$XHISPERTOOL" &> /dev/null; then
    echo "Error: xhispertool not found" >&2
    echo "Please either:" >&2
    echo "  - Run 'sudo make install' to install system-wide" >&2
    echo "  - Run 'xhisper --local' from the build directory" >&2
    exit 1
fi

# Detect clipboard tool. Prefer wl-copy only on Wayland — on X11 wl-copy has no
# display to talk to and silently fails to update the clipboard, which then makes
# the non-ASCII paste path re-paste whatever was there before.
# Also: define CLIP_COPY/CLIP_PASTE as variables, not functions — `$CLIP_COPY`
# expansion in a pipe requires the variable form (the function form expands to
# empty string, causing the pipe to silently drop the data).
if [ -n "$WAYLAND_DISPLAY" ] && command -v wl-copy &> /dev/null; then
    CLIP_COPY="wl-copy"
    CLIP_PASTE="wl-paste"
elif command -v xclip &> /dev/null; then
    CLIP_COPY="xclip -selection clipboard"
    CLIP_PASTE="xclip -o -selection clipboard"
elif command -v wl-copy &> /dev/null; then
    CLIP_COPY="wl-copy"
    CLIP_PASTE="wl-paste"
else
    echo "Error: No clipboard tool found. Install wl-clipboard or xclip." >&2
    exit 1
fi

# Resolve paste mode: auto picks clipboard-restore on Wayland, type on X11
case "$paste_mode" in
  auto)
    if [ -n "$WAYLAND_DISPLAY" ] || [ "$XDG_SESSION_TYPE" = "wayland" ]; then
      paste_mode="clipboard-restore"
    else
      paste_mode="type"
    fi
    ;;
  type|clipboard|clipboard-restore) ;;
  *)
    echo "Error: invalid paste-mode '$paste_mode' (auto|type|clipboard|clipboard-restore)" >&2
    exit 1
    ;;
esac

# Resolve placeholders mode: notify on Wayland (avoids unreliable backspace deletes), inline on X11
case "$placeholders" in
  auto)
    if [ "$paste_mode" != "type" ] && command -v notify-send &>/dev/null; then
      placeholders="notify"
    else
      placeholders="inline"
    fi
    ;;
  inline|notify|off) ;;
  *)
    echo "Error: invalid placeholders '$placeholders' (auto|inline|notify|off)" >&2
    exit 1
    ;;
esac

NOTIFY_ID_FILE="/tmp/xhisper-notify-id"

placeholder_show() {
  local msg="$1"
  dlog "placeholder show ($placeholders): \"$msg\""
  case "$placeholders" in
    inline)
      paste "$msg"
      ;;
    notify)
      local prev_id=""
      [ -f "$NOTIFY_ID_FILE" ] && prev_id=$(cat "$NOTIFY_ID_FILE" 2>/dev/null)
      local args=(-p -t 0 -i audio-input-microphone)
      [ -n "$prev_id" ] && args+=(-r "$prev_id")
      local new_id
      new_id=$(notify-send "${args[@]}" "xhisper" "$msg" 2>/dev/null)
      [ -n "$new_id" ] && echo "$new_id" > "$NOTIFY_ID_FILE"
      ;;
  esac
}

placeholder_clear_inline() {
  # Inline mode: delete N chars matching the placeholder length. No-op otherwise.
  local n="$1"
  if [ "$placeholders" = "inline" ]; then
    delete_n_chars "$n"
  fi
}

placeholder_done() {
  # Dismiss any active notification (notify mode); no-op otherwise.
  if [ "$placeholders" = "notify" ] && [ -f "$NOTIFY_ID_FILE" ]; then
    local id
    id=$(cat "$NOTIFY_ID_FILE" 2>/dev/null)
    if [ -n "$id" ]; then
      gdbus call --session --dest org.freedesktop.Notifications \
        --object-path /org/freedesktop/Notifications \
        --method org.freedesktop.Notifications.CloseNotification "$id" >/dev/null 2>&1
      dlog "placeholder dismissed (id=$id)"
    fi
    rm -f "$NOTIFY_ID_FILE"
  fi
}

press_wrap_key() {
  if [ -n "$WRAP_KEY" ]; then
    "$XHISPERTOOL" "$WRAP_KEY"
  fi
}

paste() {
  local text="$1"
  dlog "paste begin: mode=$paste_mode len=${#text} text=\"$text\""
  press_wrap_key

  if [ "$paste_mode" = "clipboard" ] || [ "$paste_mode" = "clipboard-restore" ]; then
    local saved=""
    if [ "$paste_mode" = "clipboard-restore" ]; then
      saved=$($CLIP_PASTE 2>/dev/null)
      dlog "  saved clipboard (len=${#saved})"
    fi

    printf '%s' "$text" | $CLIP_COPY
    dlog "  wl-copy returned"
    sleep "$paste_clipboard_delay"
    dlog "  slept ${paste_clipboard_delay}s, sending Ctrl+V"
    "$XHISPERTOOL" paste
    dlog "  Ctrl+V sent"

    if [ "$paste_mode" = "clipboard-restore" ]; then
      sleep "$paste_clipboard_delay"
      dlog "  slept ${paste_clipboard_delay}s, restoring clipboard"
      printf '%s' "$saved" | $CLIP_COPY
      dlog "  clipboard restored"
    fi
    press_wrap_key
    dlog "paste end"
    return
  fi

  # paste_mode=type: per-character via uinput (US QWERTY assumed),
  # fall back to clipboard for non-ASCII.
  for ((i=0; i<${#text}; i++)); do
    local char="${text:$i:1}"
    local ascii=$(printf '%d' "'$char")

    if [[ $ascii -ge 32 && $ascii -le 126 ]]; then
      "$XHISPERTOOL" type "$char"
    else
      echo -n "$char" | $CLIP_COPY
      "$XHISPERTOOL" paste
      [ "$i" -eq 0 ] && sleep "$non_ascii_initial_delay" || sleep "$non_ascii_default_delay"
    fi
  done
  press_wrap_key
  dlog "paste end (type mode)"
}

delete_n_chars() {
  local n="$1"
  dlog "delete_n_chars($n) begin"
  for ((i=0; i<n; i++)); do
    "$XHISPERTOOL" backspace
  done
  dlog "delete_n_chars($n) end"
}

get_duration() {
  local recording="$1"
  ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$recording" 2>/dev/null || echo "0"
}

is_silent() {
  local recording="$1"

  # Use ffmpeg volumedetect to get mean and max volume
  local vol_stats=$(ffmpeg -i "$recording" -af "volumedetect" -f null /dev/null 2>&1 | grep -E "mean_volume|max_volume")
  local max_vol=$(echo "$vol_stats" | grep "max_volume" | awk '{print $5}')

  # If max volume is below threshold, consider it silent
  # Note: ffmpeg reports in dB, negative values (e.g., -50 dB is quiet)
  if [ -n "$max_vol" ]; then
    local is_quiet=$(echo "$max_vol < $silence_threshold" | bc -l)
    [ "$is_quiet" -eq 1 ] && return 0
  fi

  return 1
}

transcribe() {
  local recording="$1"

  local duration
  duration=$(get_duration "$recording")
  local is_long_recording
  is_long_recording=$(echo "$duration > $long_recording_threshold" | bc -l)
  local model
  model=$([[ $is_long_recording -eq 1 ]] && echo "whisper-large-v3" || echo "whisper-large-v3-turbo")

  local lang_args=()
  [ -n "$language" ] && lang_args=(-F "language=$language")

  dlog "transcribe: request (model=$model duration=${duration}s lang=${language:-auto})"
  local t0
  t0=$(date +%s%N)

  local transcription
  transcription=$(curl -s -X POST "https://api.groq.com/openai/v1/audio/transcriptions" \
    -H "Authorization: Bearer $GROQ_API_KEY" \
    -H "Content-Type: multipart/form-data" \
    -F "file=@$recording" \
    -F "model=$model" \
    -F "prompt=$transcription_prompt" \
    "${lang_args[@]}" \
    | jq -r '.text' | sed 's/^ //') # Transcription always returns a leading space, so remove it via sed

  local elapsed
  elapsed=$(echo "scale=3; ($(date +%s%N) - $t0) / 1000000000" | bc)
  log "transcription (${elapsed}s, ${duration}s audio, ${model}): \"$transcription\""

  echo "$transcription"
}

# Main

dlog "==== invocation: argv=[$*] paste-mode=$paste_mode placeholders=$placeholders lang=${language:-auto} ===="

# Find recording process, if so then kill
if pgrep -f "$PROCESS_PATTERN" > /dev/null; then
  dlog "stop: pw-record running, sending SIGTERM"
  pkill -f "$PROCESS_PATTERN"; sleep 0.2 # Buffer for flush
  dlog "stop: pw-record flushed"
  placeholder_clear_inline "${#placeholder_recording}"

  # Check if recording is silent
  dlog "silence: checking $RECORDING"
  if is_silent "$RECORDING"; then
    log "silence detected, aborting"
    placeholder_show "$placeholder_silent"
    sleep 0.6
    placeholder_clear_inline "${#placeholder_silent}"
    placeholder_done
    rm -f "$RECORDING"
    exit 0
  fi
  dlog "silence: audio ok"

  placeholder_show "$placeholder_transcribing"
  TRANSCRIPTION=$(transcribe "$RECORDING")
  placeholder_clear_inline "${#placeholder_transcribing}"
  placeholder_done

  paste "$TRANSCRIPTION"

  rm -f "$RECORDING"
  dlog "done: transcription pasted"
else
  # No recording running, so start
  dlog "start: no pw-record running"
  sleep 0.2
  placeholder_show "$placeholder_recording"
  dlog "start: launching pw-record"
  pw-record --channels=1 --rate=16000 "$RECORDING"
  dlog "start: pw-record exited"
fi
