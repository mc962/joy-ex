// See assets/vendor for dependency info.
import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/joy"
import topbar from "../vendor/topbar"

// CodeEditor hook: handles Tab key in script textareas (inserts 2 spaces).
// Named "CodeEditor" and applied via phx-hook="CodeEditor" on <textarea>.
const CodeEditor = {
  mounted() {
    this.el.addEventListener("keydown", (e) => {
      if (e.key === "Tab") {
        e.preventDefault()
        const start = this.el.selectionStart
        const end = this.el.selectionEnd
        this.el.value = this.el.value.substring(0, start) + "  " + this.el.value.substring(end)
        this.el.selectionStart = this.el.selectionEnd = start + 2
        // Notify Phoenix LiveView of the textarea value change
        this.el.dispatchEvent(new Event("input", { bubbles: true }))
      }
    })
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
// longPollFallbackMs is explicitly disabled (null) for multi-node deployments.
//
// Background: Phoenix LiveView defaults to falling back from WebSocket to long
// polling after 2500ms if the WebSocket handshake fails. In a multi-node setup
// behind a reverse proxy / load balancer, this causes two problems:
//
// 1. sessionStorage caching (Phoenix issue #5720): when the fallback triggers,
//    the decision is cached in sessionStorage under the key "phx:longpolling".
//    Every subsequent page load in that browser tab then uses long polling for
//    the rest of the session — even after the transient WebSocket failure is
//    resolved. Users get a degraded experience with no way to recover without
//    manually clearing sessionStorage.
//
// 2. Long polling is fundamentally incompatible with standard round-robin load
//    balancing across multiple nodes. Each long-poll HTTP request can be routed
//    to a different node, but the LiveView process lives on exactly one node.
//    Requests that land on the wrong node get no response, causing the mount
//    loop to bounce indefinitely between nodes.
//
// The correct architecture for long polling in a multi-node deployment is sticky
// sessions at the load balancer (e.g. cookie-based affinity), so that all
// requests from a given client always reach the node running their LiveView
// process. Without sticky sessions, long polling does not work correctly.
//
// For this deployment: WebSocket is reliable (the reverse proxy is configured to
// pass WebSocket upgrades through), so the fallback is unnecessary. Setting
// longPollFallbackMs to null disables the fallback entirely, preventing the
// sessionStorage caching issue and the multi-node bounce problem.
//
// If longPollFallbackMs ever needs to be re-enabled (e.g. in a network
// environment where WebSocket is blocked), sticky sessions MUST be configured
// at the load balancer before doing so.
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: null,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, CodeEditor},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

liveSocket.connect()
window.liveSocket = liveSocket

if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    reloader.enableServerLogs()
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)
    window.liveReloader = reloader
  })
}
