import Foundation
import MeetingAudio
import MeetingCore
import MeetingSpeech

// `mi` — headless companion of Meeting Intelligence.
// Uses the same library as the app (override with MEETING_INTELLIGENCE_HOME).

struct CLIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: [String]) {
        var i = 0
        while i < raw.count {
            let a = raw[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < raw.count, !raw[i + 1].hasPrefix("--") {
                    options[key] = raw[i + 1]
                    i += 1
                } else {
                    flags.insert(key)
                }
            } else {
                positional.append(a)
            }
            i += 1
        }
    }
}

func printErr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

let usage = """
uso: mi <comando> [opciones]

  doctor                         Diagnóstico del entorno (modelos, apps con audio, dispositivos)
  import <archivo> [--title T] [--no-process] [--no-diarize]
                                 Importa audio y lo procesa con Parakeet Ultra
  process <meetingId> [--no-diarize] [--no-local-diarization] [--boost-vocabulary]
  list                           Lista reuniones
  show <meetingId>               Muestra la transcripción con hablantes y timestamps
  search <consulta> [--meeting ID] [--speaker NOMBRE] [--semantic]
  semantic-index                 Descarga e5-small (una vez) e indexa los fragmentos para --semantic
  models [update <id>]           Versiones de los modelos (consulta Hugging Face) y actualización verificada
  export <meetingId> --format txt|markdown|json|srt|pdf [--out ruta]
  ai-providers                   Detecta proveedores de IA (versión, sesión, modelos)
  analyze <meetingId> --provider claude|codex|agy|ollama [--model M] [--effort E] [--share]
                                 Analiza con IA; los proveedores en la nube exigen --share
  ask <pregunta> [--meeting ID] [--provider P] [--share] [--semantic] [--save]
                                 Pregunta sobre reuniones (búsqueda local + IA opcional)
  evaluate <audio> [--reference ref.txt] [--rttm ref.rttm] [--no-diarize]
                                 Mide WER/DER/RTFx sin modificar la biblioteca
"""

@main
struct MeetingIntelligenceCLI {
    static func main() async {
        var raw = Array(CommandLine.arguments.dropFirst())
        guard let command = raw.first else {
            print(usage)
            exit(0)
        }
        raw.removeFirst()
        let args = Arguments(raw)
        do {
            let paths = AppPaths.resolveDefault()
            switch command {
            case "doctor": try await Commands.doctor(paths: paths)
            case "import": try await Commands.importFile(args, paths: paths)
            case "process": try await Commands.process(args, paths: paths)
            case "list": try Commands.list(paths: paths)
            case "show": try Commands.show(args, paths: paths)
            case "search": try await Commands.search(args, paths: paths)
            case "semantic-index": try await Commands.semanticIndex(paths: paths)
            case "models": try await Commands.models(args, paths: paths)
            case "export": try Commands.export(args, paths: paths)
            case "ai-providers": await Commands.aiProviders(paths: paths)
            case "analyze": try await Commands.analyze(args, paths: paths)
            case "ask": try await Commands.ask(args, paths: paths)
            case "evaluate": try await Commands.evaluate(args)
            case "help", "-h", "--help": print(usage)
            default:
                printErr("Comando desconocido: \(command)\n\n\(usage)")
                exit(2)
            }
        } catch {
            printErr("error: \(error.localizedDescription)")
            exit(1)
        }
    }
}
