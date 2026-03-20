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
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
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
