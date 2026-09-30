// Minimal server-rendered pages. No scripts, no third-party assets.

function esc(s: string): string {
  return s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
}

function layout(title: string, body: string): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><meta name="referrer" content="same-origin">
<title>${esc(title)}</title><style>
body{font-family:system-ui,sans-serif;max-width:32rem;margin:2rem auto;padding:0 1rem;line-height:1.4}
.code{font-size:2.5rem;letter-spacing:.3rem;font-weight:700;text-align:center;margin:1rem 0}
button{font-size:1.1rem;padding:.7rem 1.2rem;width:100%;margin-top:1rem}
.warn{background:#fff4d6;border:1px solid #e0b400;padding:.7rem;border-radius:.4rem}
</style></head><body><h1>${esc(title)}</h1>${body}</body></html>`;
}

export function start(id: string, csrf: string, retry: boolean): string {
  return layout(
    "Connect KOReader to Google Photos",
    `<p>This will let the e-reader showing the QR code upload images into Google Photos
(add-only access: it cannot read, change or delete your existing photos).</p>
<p>Only continue if you scanned the QR code on <strong>your own reader</strong> just now.</p>
${retry ? "<p>A previous sign-in attempt was not completed. You can try again.</p>" : ""}
<form method="post" action="/p/${esc(id)}/start"><input type="hidden" name="csrf" value="${esc(csrf)}">
<button type="submit">Sign in with Google</button></form>`,
  );
}

export function confirm(id: string, csrf: string, code: string): string {
  return layout(
    "Confirm the code",
    `<p>Your reader should now show this code:</p><div class="code">${esc(code)}</div>
<p class="warn">Only confirm if the <strong>same code</strong> is shown on the reader in front of you.
If it differs, or you did not start this, close this page: someone else's device may be trying to connect.</p>
<form method="post" action="/p/${esc(id)}/confirm"><input type="hidden" name="csrf" value="${esc(csrf)}">
<button type="submit">The codes match</button></form>`,
  );
}

export function done(): string {
  return layout(
    "Almost done",
    "<p>Phone side confirmed. Finish on the reader by confirming the same code there. You can close this page.</p>",
  );
}

export function claimed(): string {
  return layout(
    "Pairing already in use",
    "<p>This pairing was already started from another browser. Restart pairing on the reader to get a new QR code.</p>",
  );
}

export function expired(): string {
  return layout("Pairing expired", "<p>This pairing link is invalid or expired. Start pairing again on the reader.</p>");
}

export function message(title: string, text: string): string {
  return layout(title, `<p>${esc(text)}</p>`);
}
