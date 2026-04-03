import SwiftUI
import UIKit
import WebKit

struct ImageStripView: View {
    let pageData: [Data]
    @State private var selectedImage: ZoomableImageItem?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(pageData.enumerated()), id: \.offset) { index, data in
                    if let image = UIImage(data: data) {
                        Button {
                            selectedImage = ZoomableImageItem(image: image, title: "Page \(index + 1)")
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(Color(.secondarySystemBackground))

                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFit()
                                        .padding(8)
                                }
                                .frame(width: 150, height: 200)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14)
                                        .strokeBorder(.quaternary, lineWidth: 1)
                                }
                                Text("Page \(index + 1)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .fullScreenCover(item: $selectedImage) { item in
            FullScreenImageViewer(item: item)
        }
    }
}

struct RenderedTextBlock: View {
    let text: String
    var maxPreviewHeight: CGFloat? = 260
    @State private var contentHeight: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MathRenderedTextView(text: text, contentHeight: $contentHeight)
                .frame(height: previewHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            if let maxPreviewHeight, contentHeight > maxPreviewHeight {
                Text("Scroll to view more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 12)
        .padding(.horizontal, 12)
        .padding(.bottom, 16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white)
        )
    }

    private var previewHeight: CGFloat {
        let naturalHeight = max(contentHeight + 28, 84)
        if let maxPreviewHeight {
            return min(naturalHeight, maxPreviewHeight)
        }
        return naturalHeight
    }
}

struct RenderedPreviewButton: View {
    let title: String
    let text: String
    @State private var showingPreview = false

    var body: some View {
        Button {
            showingPreview = true
        } label: {
            Label("Preview Render", systemImage: "text.viewfinder")
                .font(.subheadline)
        }
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .sheet(isPresented: $showingPreview) {
            RenderedPreviewSheet(title: title, text: text)
        }
    }
}

private struct RenderedPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let text: String

    var body: some View {
        NavigationStack {
            ScrollView {
                RenderedTextBlock(text: text, maxPreviewHeight: nil)
                    .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct MathRenderedTextView: UIViewRepresentable {
    let text: String
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(contentHeight: $contentHeight)
    }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "contentHeight")

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.showsVerticalScrollIndicator = true
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.bounces = true
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let html = htmlDocument(for: text)
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "contentHeight")
    }

    private func htmlDocument(for text: String) -> String {
        let normalized = normalizeMathPreviewText(text)
        let escaped = normalized
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\n", with: "<br/>")

        return """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0">
          <style>
            body {
              margin: 0;
              padding: 0;
              background: transparent;
              color: #111827;
              font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif;
              font-size: 17px;
              line-height: 1.45;
              overflow-wrap: break-word;
            }
            .wrap {
              width: 100%;
              background: transparent;
              padding: 2px 0 10px 0;
              overflow-wrap: anywhere;
            }
            p { margin: 0 0 0.9em 0; }
            mjx-container {
              margin: 0.15em 0 !important;
              overflow-x: auto;
              overflow-y: visible;
              max-width: 100%;
            }
            mjx-container[display="true"] {
              display: block !important;
              margin: 0.55em 0 !important;
            }
            mjx-container[jax="CHTML"] {
              white-space: normal !important;
            }
          </style>
          <script>
            window.MathJax = {
              tex: {
                inlineMath: [['$', '$'], ['\\\\(', '\\\\)']],
                displayMath: [['$$', '$$'], ['\\\\[', '\\\\]']],
                processEscapes: true
              },
              options: {
                skipHtmlTags: ['script', 'noscript', 'style', 'textarea', 'pre', 'code']
              },
              chtml: {
                scale: 1
              },
              startup: {
                typeset: false
              }
            };

            function reportHeight() {
              const content = document.getElementById('content');
              const rectHeight = content ? content.getBoundingClientRect().height : 0;
              const scrollHeight = content ? content.scrollHeight : 0;
              const height = Math.max(rectHeight, scrollHeight, 44);
              window.webkit.messageHandlers.contentHeight.postMessage(height);
            }

            function installHeightObservers() {
              if (window.__heightObserversInstalled) return;
              window.__heightObserversInstalled = true;

              if (window.ResizeObserver) {
                const ro = new ResizeObserver(function() {
                  reportHeight();
                });
                ro.observe(document.body);
                ro.observe(document.documentElement);
              }

              const mo = new MutationObserver(function() {
                reportHeight();
              });
              mo.observe(document.body, { childList: true, subtree: true, characterData: true });

              window.addEventListener('resize', reportHeight);
            }

            function burstHeightReports() {
              [0, 40, 120, 250, 500, 900, 1400].forEach(function(delay) {
                setTimeout(reportHeight, delay);
              });
            }

            function waitForMathJax(retries) {
              if (window.MathJax && window.MathJax.typesetPromise) {
                MathJax.typesetPromise([document.getElementById('content')]).then(function() {
                  burstHeightReports();
                }).catch(function() {
                  burstHeightReports();
                });
                return;
              }

              if (retries > 0) {
                setTimeout(function() {
                  waitForMathJax(retries - 1);
                }, 75);
              } else {
                burstHeightReports();
              }
            }

            window.addEventListener('load', function() {
              installHeightObservers();
              waitForMathJax(80);
            });
          </script>
          <script async src="https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-chtml.js"></script>
        </head>
        <body>
          <div id="content" class="wrap">\(escaped)</div>
        </body>
        </html>
        """
    }

    private func normalizeMathPreviewText(_ text: String) -> String {
        let unicodeDecoded = decodeUnicodeEscapes(in: text)
        let normalized = unicodeDecoded
            .replacingOccurrences(of: "\\\\(", with: "\\(")
            .replacingOccurrences(of: "\\\\)", with: "\\)")
            .replacingOccurrences(of: "\\\\[", with: "\\[")
            .replacingOccurrences(of: "\\\\]", with: "\\]")
            .replacingOccurrences(of: "\\rac", with: "\\frac")
            .replacingOccurrences(of: "\\\\frac", with: "\\frac")
            .replacingOccurrences(of: "\\\\cdot", with: "\\cdot")
            .replacingOccurrences(of: "\\\\times", with: "\\times")
            .replacingOccurrences(of: "\\\\left", with: "\\left")
            .replacingOccurrences(of: "\\\\right", with: "\\right")
            .replacingOccurrences(of: "\\\\tilde", with: "\\tilde")

        return trimWhitespaceInsideMathDelimiters(in: normalized)
    }

    private func decodeUnicodeEscapes(in text: String) -> String {
        var result = ""
        var index = text.startIndex

        while index < text.endIndex {
            if text[index] == "\\",
               let uIndex = text.index(index, offsetBy: 1, limitedBy: text.endIndex),
               uIndex < text.endIndex,
               text[uIndex] == "u" {
                let hexStart = text.index(after: uIndex)
                let hexEnd = text.index(hexStart, offsetBy: 4, limitedBy: text.endIndex) ?? text.endIndex
                let hex = String(text[hexStart..<hexEnd])

                if hex.count == 4,
                   let scalarValue = UInt32(hex, radix: 16),
                   let scalar = UnicodeScalar(scalarValue) {
                    result.unicodeScalars.append(scalar)
                    index = hexEnd
                    continue
                }
            }

            result.append(text[index])
            index = text.index(after: index)
        }

        return result
    }

    private func trimWhitespaceInsideMathDelimiters(in text: String) -> String {
        var output = text
        output = replaceDelimitedMath(in: output, pattern: #"\$\$(.+?)\$\$"#, prefix: "$$", suffix: "$$")
        output = replaceDelimitedMath(in: output, pattern: #"\$(?!\$)(.+?)(?<!\$)\$"#, prefix: "$", suffix: "$")
        output = replaceDelimitedMath(in: output, pattern: #"\\\((.+?)\\\)"#, prefix: "\\(", suffix: "\\)")
        output = replaceDelimitedMath(in: output, pattern: #"\\\[(.+?)\\\]"#, prefix: "\\[", suffix: "\\]")
        return output
    }

    private func replaceDelimitedMath(in text: String, pattern: String, prefix: String, suffix: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return text
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        var result = text

        for match in matches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }
            let body = nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = prefix + body + suffix
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: replacement)
            }
        }

        return result
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        @Binding var contentHeight: CGFloat
        var lastHTML = ""

        init(contentHeight: Binding<CGFloat>) {
            _contentHeight = contentHeight
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "contentHeight" else { return }

            if let height = message.body as? CGFloat {
                DispatchQueue.main.async {
                    self.contentHeight = max(height, 44)
                }
            } else if let height = message.body as? Double {
                DispatchQueue.main.async {
                    self.contentHeight = max(height, 44)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("installHeightObservers(); waitForMathJax(80); burstHeightReports();", completionHandler: nil)
        }
    }
}

private struct ZoomableImageItem: Identifiable {
    let id = UUID()
    let image: UIImage
    let title: String
}

private struct FullScreenImageViewer: View {
    @Environment(\.dismiss) private var dismiss
    let item: ZoomableImageItem

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            ZoomableImageScrollView(image: item.image)
                .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.95))
                    .padding()
            }
        }
        .overlay(alignment: .topLeading) {
            Text(item.title)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.9))
                .padding()
        }
        .statusBarHidden()
    }
}

private struct ZoomableImageScrollView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator {
        Coordinator(image: image)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 6
        scrollView.minimumZoomScale = 1
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .black

        let imageView = context.coordinator.imageView
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.addSubview(imageView)

        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.imageView.image = image
        context.coordinator.imageView.frame = uiView.bounds
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()

        init(image: UIImage) {
            super.init()
            imageView.image = image
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }
    }
}
