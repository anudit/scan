import Foundation
import QuickLookUI
import UniformTypeIdentifiers
import ScanEngine
import ScanQuery

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    @objc(providePreviewForFileRequest:completionHandler:)
    func providePreview(for request: QLFilePreviewRequest,
                        completionHandler: @escaping @Sendable (QLPreviewReply?, Error?) -> Void) {
        let url = request.fileURL
        Task {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let engine = try Engine(memoryMB: 128, threads: 2)
                let info = try await engine.open(url, previewLimit: 10)
                let page = try await engine.preview(limit: 10)
                let html = Self.renderHTML(name: url.lastPathComponent, columns: info.columns, page: page)
                let reply = QLPreviewReply(dataOfContentType: .html,
                                           contentSize: CGSize(width: 1100, height: 560)) { _ in Data(html.utf8) }
                reply.title = url.lastPathComponent
                completionHandler(reply, nil)
            } catch {
                completionHandler(nil, error)
            }
        }
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func renderHTML(name: String, columns: [Column], page: RowPage) -> String {
        let heads = columns.map { "<th><span>\(escape($0.name))</span><small>\(escape($0.type))</small></th>" }.joined()
        let rows = (0..<page.count).map { row in
            let cells = columns.indices.map { column -> String in
                let value = page.columns[column][row]
                return "<td\(value == nil ? " class='null'" : "")>\(escape(value ?? "NULL"))</td>"
            }.joined()
            return "<tr><th class='rownum'>\(row + 1)</th>\(cells)</tr>"
        }.joined()
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>
        :root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;background:#111318;color:#e4e8ed;font:13px -apple-system,BlinkMacSystemFont,sans-serif}
        header{padding:18px 22px;background:#1b1f27;border-bottom:1px solid #303744}h1{font-size:17px;margin:0 0 5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}p{margin:0;color:#9ca5b3;font-size:12px}
        main{overflow:auto;height:calc(100vh - 76px)}table{border-collapse:collapse;min-width:100%;width:max-content}th,td{border-right:1px solid #303744;border-bottom:1px solid #303744;text-align:left;padding:8px 11px;max-width:280px;min-width:100px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        thead th{position:sticky;top:0;background:#252b35;z-index:2}thead th span,thead th small{display:block}thead th small{margin-top:3px;color:#9ca5b3;font-size:10px;font-weight:normal}.rownum{position:sticky;left:0;min-width:46px;max-width:46px;background:#1b1f27;color:#8a94a2;text-align:right;font-weight:normal;z-index:1}thead .rownum{z-index:3}tbody tr:nth-child(even){background:#191d24}.null{color:#eb6b60;font-style:italic}
        </style></head><body><header><h1>\(escape(name))</h1><p>\(columns.count) columns · first \(page.count) rows</p></header><main><table><thead><tr><th class="rownum">#</th>\(heads)</tr></thead><tbody>\(rows)</tbody></table></main></body></html>
        """
    }
}
