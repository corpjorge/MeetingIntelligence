#!/bin/zsh
# Regenerates THIRD_PARTY_NOTICES.md from the resolved SwiftPM dependencies
# (Package.resolved + .build/checkouts) and FluidAudio's own third-party notices.
# Run after `scripts/swiftw package resolve`; the release packaging calls it.
set -euo pipefail
ROOT="${0:A:h:h}"
OUT="$ROOT/THIRD_PARTY_NOTICES.md"
CHECKOUTS="$ROOT/.build/checkouts"

{
  print "# Avisos de terceros"
  print
  print "Meeting Intelligence incluye, enlazadas en sus ejecutables, las bibliotecas siguientes. Cada una se distribuye"
  print "bajo su propia licencia, reproducida abajo. Archivo generado por \`scripts/third-party-notices.sh\`."
  print
  print "## Modelos (no incluidos en la app)"
  print
  print "La app descarga estos modelos de Hugging Face solo cuando el usuario lo solicita; se usan bajo sus licencias:"
  print
  print "| Modelo | Uso | Licencia |"
  print "|---|---|---|"
  print "| [FluidInference/parakeet-ultra-coreml](https://huggingface.co/FluidInference/parakeet-ultra-coreml) (derivado de NVIDIA Parakeet) | Transcripción | CC-BY-4.0 |"
  print "| [FluidInference/speaker-diarization-coreml](https://huggingface.co/FluidInference/speaker-diarization-coreml) (pyannote community-1 + WeSpeaker) | Diarización | CC-BY-4.0 con alcance indicado en su NOTICE.md |"
  print "| [FluidInference/parakeet-ctc-110m-coreml](https://huggingface.co/FluidInference/parakeet-ctc-110m-coreml) | Refuerzo del diccionario (opcional) | CC-BY-4.0 |"
  print "| [intfloat/multilingual-e5-small](https://huggingface.co/intfloat/multilingual-e5-small) | Búsqueda semántica (opcional) | MIT |"
  print
  print "## Bibliotecas"
  python3 -I - "$ROOT/Package.resolved" <<'PY' | while IFS='|' read -r identity location version; do
import json, sys
for pin in sorted(json.load(open(sys.argv[1]))["pins"], key=lambda p: p["identity"]):
    state = pin["state"]
    print(f'{pin["identity"]}|{pin["location"]}|{state.get("version") or state.get("revision", "")[:12]}')
PY
    dir=""
    for candidate in "$CHECKOUTS"/*(N/); do
      [[ "${candidate:t:l}" == "${identity:l}" ]] && dir="$candidate"
    done
    [[ -n "$dir" ]] || continue
    license=$(ls "$dir" | grep -iE '^(license|licence|copying)' | head -1 || true)
    [[ -n "$license" ]] || continue
    print
    print "### ${dir:t} ${version}"
    print
    print "Fuente: ${location}"
    print
    print '```'
    cat "$dir/$license"
    print '```'
  done
  print
  print "### SentencePiece (binario incluido por swift-sentencepiece)"
  print
  print "Fuente: https://github.com/google/sentencepiece — Copyright Google LLC. Apache License 2.0"
  print "(texto completo arriba, en las bibliotecas con licencia Apache-2.0)."
  for extra in "$CHECKOUTS"/FluidAudio/ThirdPartyLicenses/*.md(N); do
    print
    print "### FluidAudio · ${extra:t:r}"
    print
    print '```'
    cat "$extra"
    print '```'
  done
} > "$OUT"
print "✓ $OUT"
