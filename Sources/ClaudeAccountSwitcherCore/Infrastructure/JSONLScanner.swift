import Foundation

/// Leitor de `.jsonl` em streaming para os logs de sessão do Claude Code.
///
/// Por que existe: o `.jsonl` da sessão ativa pode ter dezenas de MB e cresce a cada mensagem.
/// Ler o arquivo inteiro em `Data`, copiar para `String`, repartir em linhas e passar TODAS elas
/// pelo `JSONSerialization` custa ~3× o tamanho do arquivo em RAM de pico e CPU proporcional —
/// a cada refresh. Aqui:
/// - lê em blocos de 1 MB (memória = bloco + maior linha);
/// - descarta, por busca de bytes (`memmem`), toda linha que não contém o marcador (em geral só
///   ~15% das linhas são `assistant`; o resto é tool-result gigante) SEM copiá-la nem parseá-la;
/// - retoma de um offset, para que um arquivo append-only só processe os bytes novos.
enum JSONLScanner {
    static let chunkSize = 1 << 20
    static let headLength = 512

    /// Marcador das linhas de mensagem do assistente (JSON compacto, como o CLI grava).
    static let assistantMarker: [UInt8] = Array(#""type":"assistant""#.utf8)

    /// Primeiros bytes do arquivo — impressão digital para detectar que ele foi REescrito (e não
    /// apenas acrescido) entre dois scans, caso em que o offset salvo deixa de valer.
    static func head(of url: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return ((try? handle.read(upToCount: headLength)) ?? nil) ?? Data()
    }

    /// Chama `body` para cada linha completa a partir de `offset` que contém `marker`. O `Data`
    /// entregue só é válido durante a chamada (aponta para o buffer interno, sem cópia).
    /// Uma última linha sem `\n` só é consumida se for um objeto JSON completo; caso
    /// contrário é uma escrita em andamento e fica para o próximo scan.
    /// - Returns: o offset logo após a última linha consumida, ou `nil` se o arquivo for ilegível.
    @discardableResult
    static func scan(_ url: URL, from offset: UInt64 = 0, matching marker: [UInt8] = assistantMarker, _ body: (Data) -> Void) -> UInt64? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: offset) } catch { return nil }

        var consumed = offset
        var pending = Data()

        func emit(_ base: UnsafePointer<UInt8>, _ count: Int) {
            // Marcador vazio = todas as linhas (cópia de backup do `SessionArchive`).
            if !marker.isEmpty {
                guard count >= marker.count else { return }
                let found = marker.withUnsafeBytes { memmem(base, count, $0.baseAddress!, marker.count) }
                guard found != nil else { return }
            }
            // Pool por linha: o `JSONSerialization` devolve objetos Foundation autoreleased que, numa
            // thread de background sem run loop, só seriam liberados no fim da tarefa inteira
            // (centenas de MB acumulados num scan frio).
            autoreleasepool {
                body(Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: count, deallocator: .none))
            }
        }

        // Pool por bloco: `FileHandle.read` devolve `Data` autoreleased de 1 MB; sem drenar, todos os
        // blocos do arquivo (e dos próximos arquivos do mesmo ciclo) ficariam vivos até o fim da tarefa.
        var reachedEOF = false
        while !reachedEOF {
            autoreleasepool {
                guard let chunk = (try? handle.read(upToCount: chunkSize)) ?? nil, !chunk.isEmpty else { reachedEOF = true; return }
                pending.append(chunk)
                var lineStart = 0
                pending.withUnsafeBytes { raw in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                    let count = raw.count
                    while lineStart < count, let hit = memchr(base + lineStart, 0x0A, count - lineStart) {
                        let end = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                        emit(base + lineStart, end - lineStart)
                        consumed += UInt64(end - lineStart + 1)
                        lineStart = end + 1
                    }
                }
                if lineStart > 0 { pending = Data(pending.dropFirst(lineStart)) }
            }
        }

        if !pending.isEmpty {
            pending.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                var end = raw.count
                while end > 0, base[end - 1] == 0x20 || base[end - 1] == 0x0D || base[end - 1] == 0x09 { end -= 1 }
                guard end > 0, base[end - 1] == UInt8(ascii: "}") else { return }
                // Terminar em `}` não basta: um corte no meio de um objeto aninhado também termina
                // assim. Só consome (e avança o offset) se o objeto parsear por inteiro.
                let candidate = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: end, deallocator: .none)
                guard (try? JSONSerialization.jsonObject(with: candidate)) != nil else { return }
                emit(base, end)
                consumed += UInt64(raw.count)
            }
        }
        return consumed
    }
}
