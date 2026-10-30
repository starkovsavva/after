import CryptoKit
import Foundation

/// This page acknowledges only the browser handoff. Token verification and the
/// final sign-in result belong to the native application. No callback value is
/// interpolated into the document, and all assets are embedded.
enum ChatGPTCallbackPage {
    static var contentSecurityPolicy: String {
        let hash = Data(SHA256.hash(data: Data(styles.utf8))).base64EncodedString()
        return "default-src 'none'; style-src 'sha256-\(hash)'; img-src data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
    }

    static func body(received: Bool) -> Data {
        let title = received ? L("Возвращаемся в «After»") : L("Вернитесь в «After»")
        let message = received
            ? L("Результат входа появится в приложении.")
            : L("Не удалось продолжить вход. Начните подключение заново в приложении.")
        let guidance = received
            ? L("Если окно не появилось, откройте «After» из Dock.")
            : L("Откройте «After» из Dock, чтобы попробовать ещё раз.")
        let favicon = Data(logo.utf8).base64EncodedString()
        return Data("""
        <!doctype html>
        <html lang="\(UILocale().language.languageCode?.identifier ?? "en")">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="color-scheme" content="light dark">
          <meta name="referrer" content="no-referrer">
          <title>\(title)</title>
          <link rel="icon" type="image/svg+xml" href="data:image/svg+xml;base64,\(favicon)">
          <style>\(styles)</style>
        </head>
        <body>
          <main aria-labelledby="title">
            <div class="mark" aria-hidden="true">\(logo)</div>
            <h1 id="title">\(title)</h1>
            <p class="message">\(message)</p>
            <div class="guidance">
              <p>\(guidance)</p>
              <p>\(L("Эту вкладку можно закрыть."))</p>
            </div>
          </main>
        </body>
        </html>
        """.utf8)
    }

    private static let logo = BrandArtwork.svg

    private static let styles = #"""
    :root {
      color-scheme: light dark;
      --background: #f5f5f7;
      --text: #1d1d1f;
      --secondary: #5c5c61;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --background: #1c1c1e;
        --text: #f5f5f7;
        --secondary: #a1a1a6;
      }
    }
    * { box-sizing: border-box; }
    html { min-height: 100%; background: var(--background); }
    body {
      margin: 0;
      min-height: 100vh;
      min-height: 100svh;
      display: grid;
      place-items: center;
      padding: 40px 24px;
      color: var(--text);
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      -webkit-font-smoothing: antialiased;
      text-align: center;
    }
    main { width: 100%; max-width: 440px; }
    .mark { display: flex; justify-content: center; margin-bottom: 26px; }
    .mark svg { display: block; width: 60px; height: 60px; }
    h1 {
      margin: 0;
      font-size: clamp(25px, 4vw, 30px);
      font-weight: 600;
      line-height: 1.2;
      letter-spacing: -0.025em;
      text-wrap: balance;
    }
    .message { margin: 14px 0 0; font-size: 16px; line-height: 1.5; text-wrap: pretty; }
    .guidance { margin-top: 30px; color: var(--secondary); font-size: 13px; line-height: 1.5; }
    .guidance p { margin: 0; }
    .guidance p + p { margin-top: 6px; }
    @media (max-height: 400px) {
      body { padding-block: 24px; }
      .mark { margin-bottom: 18px; }
      .guidance { margin-top: 20px; }
    }
    """#
}
