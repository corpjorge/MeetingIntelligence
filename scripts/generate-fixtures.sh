#!/bin/zsh
# Generates SYNTHETIC, explicitly-labelled test fixtures with macOS system voices.
#
# These fixtures exercise the pipeline end to end (Spanish ASR, mixed English
# terminology, two speakers, overlap, silence, noise). They are NOT a substitute
# for authorized real meeting recordings: TTS speech is cleaner and more regular
# than real speech, so WER/DER measured on them is an optimistic lower bound.
#
# Output: Fixtures/synthetic/<name>.wav (16 kHz mono PCM) + <name>.txt reference
#         Fixtures/synthetic/<name>.rttm for multi-speaker fixtures.
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="$ROOT/Fixtures/synthetic"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

VOICE_A="Paulina"   # es_MX
VOICE_B="Eddy (Español (México))"  # es_MX, different speaker
VOICE_C="Mónica"    # es_ES

render() { # voice text out.wav
  say -v "$1" -o "$WORK/tmp.aiff" "$2"
  ffmpeg -loglevel error -y -i "$WORK/tmp.aiff" -ar 16000 -ac 1 -c:a pcm_s16le "$3"
}
duration() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"; }
silence() { # seconds out.wav
  ffmpeg -loglevel error -y -f lavfi -i "anullsrc=r=16000:cl=mono" -t "$1" -c:a pcm_s16le "$2"
}

# 1. Single speaker, Spanish with English software/finance terms.
T1="El servicio de viabilidad inicial debe exponer el indicador de ingresos validados en el response del endpoint. También necesitamos revisar el pull request del microservicio de onboarding antes del viernes. El equipo de backend va a desplegar en Kubernetes y medir la latencia del API."
render "$VOICE_A" "$T1" "$OUT/es_single_speaker.wav"
print -r -- "$T1" > "$OUT/es_single_speaker.txt"

# 2. Two speakers alternating with pauses (+ RTTM ground truth).
typeset -a SPK TXT
SPK=(A B A B)
TXT=(
  "Buenos días. Hoy vamos a revisar los requerimientos del módulo de crédito."
  "Perfecto. Yo me encargo de documentar los campos del response y las validaciones."
  "Necesitamos que el campo de ingresos validados quede expuesto antes del quince de noviembre."
  "De acuerdo, lo dejo listo en el sprint actual y aviso al equipo de QA."
)
: > "$OUT/es_two_speakers.txt"
: > "$OUT/es_two_speakers.rttm"
CONCAT="$WORK/list.txt"; : > "$CONCAT"
silence 0.8 "$WORK/gap.wav"
t=0
for i in {1..4}; do
  v=$VOICE_A; [[ ${SPK[$i]} == B ]] && v=$VOICE_B
  render "$v" "${TXT[$i]}" "$WORK/turn$i.wav"
  d=$(duration "$WORK/turn$i.wav")
  printf "SPEAKER es_two_speakers 1 %.3f %.3f <NA> <NA> %s <NA> <NA>\n" "$t" "$d" "${SPK[$i]}" >> "$OUT/es_two_speakers.rttm"
  print -r -- "${TXT[$i]}" >> "$OUT/es_two_speakers.txt"
  print "file '$WORK/turn$i.wav'" >> "$CONCAT"
  print "file '$WORK/gap.wav'" >> "$CONCAT"
  t=$(( t + d + 0.8 ))
done
ffmpeg -loglevel error -y -f concat -safe 0 -i "$CONCAT" -c:a pcm_s16le "$OUT/es_two_speakers.wav"

# 3. Overlapping speech (two voices mixed with a 1.5 s offset).
render "$VOICE_A" "Estoy de acuerdo con la propuesta de arquitectura." "$WORK/o1.wav"
render "$VOICE_C" "Yo creo que primero debemos validar el presupuesto." "$WORK/o2.wav"
ffmpeg -loglevel error -y -i "$WORK/o1.wav" -i "$WORK/o2.wav" \
  -filter_complex "[1]adelay=1500[b];[0][b]amix=inputs=2:duration=longest:normalize=0" \
  -ar 16000 -ac 1 -c:a pcm_s16le "$OUT/es_overlap.wav"
print -r -- "Estoy de acuerdo con la propuesta de arquitectura. Yo creo que primero debemos validar el presupuesto." > "$OUT/es_overlap.txt"

# 4. Silence only (must produce no text).
silence 12 "$OUT/silence.wav"
: > "$OUT/silence.txt"

# 5. Degraded audio: single-speaker fixture + pink noise at ~10 dB SNR, band-limited.
ffmpeg -loglevel error -y -i "$OUT/es_single_speaker.wav" \
  -f lavfi -i "anoisesrc=color=pink:amplitude=0.06:sample_rate=16000" \
  -filter_complex "[0]highpass=f=300,lowpass=f=3400[s];[s][1]amix=inputs=2:duration=first:normalize=0" \
  -ar 16000 -ac 1 -c:a pcm_s16le "$OUT/es_noisy.wav"
cp "$OUT/es_single_speaker.txt" "$OUT/es_noisy.txt"

# 6. Very short reply surrounded by silence: ASR finds words but the diarizer
#    cannot extract any speaker embedding (reproduces "No speech detected").
render "$VOICE_A" "Sí, claro." "$WORK/short.wav"
silence 8 "$WORK/pad.wav"
ffmpeg -loglevel error -y -i "$WORK/pad.wav" -i "$WORK/short.wav" -i "$WORK/pad.wav" \
  -filter_complex "[0:a][1:a][2:a]concat=n=3:v=0:a=1" -ar 16000 -ac 1 -c:a pcm_s16le "$OUT/es_short_reply.wav"
print -r -- "Sí, claro." > "$OUT/es_short_reply.txt"

# 7-8. Short utterance isolated in digital silence (paused mic / silent system
#      audio). Decoded as is, Parakeet drifts to another language ("Hello, como
#      está?", "Valeu, né?"); collapsing dead silence before ASR fixes it (TD-22).
silence 3.5 "$WORK/lead.wav"
silence 15 "$WORK/tail.wav"
isolated() { # voice text name
  render "$1" "$2" "$WORK/isolated.wav"
  ffmpeg -loglevel error -y -i "$WORK/lead.wav" -i "$WORK/isolated.wav" -i "$WORK/tail.wav" \
    -filter_complex "[0:a][1:a][2:a]concat=n=3:v=0:a=1" -ar 16000 -ac 1 -c:a pcm_s16le "$OUT/$3.wav"
  print -r -- "$2" > "$OUT/$3.txt"
}
isolated "$VOICE_B" "Aló, ¿cómo está?" es_isolated_greeting
isolated "$VOICE_A" "Vale." es_isolated_word

# 9. One short reply with no same-track context. The isolated decoder drifts;
#    nearby Spanish from the remote track lets the pipeline recover it.
render "$VOICE_C" "¿Ya está?" "$OUT/es_context_reply.wav"
print -r -- "¿Ya está?" > "$OUT/es_context_reply.txt"

cat > "$OUT/README.md" <<'EOF'
# Synthetic fixtures (FIXTURE — not real meetings)

Generated by `scripts/generate-fixtures.sh` with macOS system voices (`say`).
They contain no real people and no real meeting content.

| File | Purpose |
|---|---|
| es_single_speaker | Spanish + English technical terms, one voice |
| es_two_speakers | Two alternating voices, RTTM ground truth |
| es_overlap | Two voices overlapping |
| silence | 12 s of digital silence (expect empty transcript) |
| es_noisy | Band-limited + pink noise (~telephone quality) |
| es_short_reply | 1.2 s reply between 8 s of silence (words, but nothing to diarize) |
| es_isolated_greeting | "Aló, ¿cómo está?" after 3.5 s and before 15 s of digital silence (language drift, TD-22) |
| es_isolated_word | "Vale." isolated the same way (language drift, TD-22) |
| es_context_reply | "¿Ya está?" with no same-track context; remote-track context recovery |

WER/DER on TTS audio is an optimistic bound. Real accuracy must be measured
on authorized real recordings (see TESTING.md).
EOF
ls -la "$OUT"
