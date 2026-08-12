const ENDPOINT = "http://127.0.0.1:51847";

// The ONLY place that talks to the app. A content script's fetch would carry
// instagram.com as its origin and the app would reject it — correctly.
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg?.type !== "grab") return false;
  fetch(`${ENDPOINT}/grab`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ url: msg.url, browser: msg.browser }),
  })
    .then((r) => sendResponse({ status: r.status }))
    .catch((e) => sendResponse({ error: String(e) }));
  return true; // keep the message channel open for the async reply
});
