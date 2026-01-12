import * as EditorComm from "../editor_comm.js";

const EditorHooks = {
  mounted() {
    // No longer adding editor-page class to allow scrolling
  },
  destroyed() {
    // No cleanup needed
  },
};

// Listen for add-body-class event
window.addEventListener("phx:add-body-class", (e) => {
  if (e.detail && e.detail.class) {
    // Commented out to allow scrolling
    // document.body.classList.add(e.detail.class);
  }
});

// Hooks for connecting LiveView with editor components
export const EditorCommunicationHook = {
  mounted() {
    console.log("EditorCommunicationHook mounted on:", this.el.id);

    // Set up the global hook for communication
    EditorComm.setHook(this);

    // Store hook instance in window for direct access from other scripts
    window.editorCommHook = this;

    // Listen for custom selection entity update events
    document.addEventListener("haimeda:selection-entity-update", (event) => {
      console.log("Received selection entity update event:", event.detail);
      this.pushEvent("selection-entity-update", event.detail);
    });

    // Also listen for these events at the document level to ensure capture
    document.addEventListener("selection-entity-update", (event) => {
      console.log(
        "Caught document-level selection entity update:",
        event.detail
      );
      if (event.detail && event.detail.entity_id) {
        this.pushEvent("selection-entity-update", event.detail);
      }
    });

    // Let clients know we're ready to communicate
    window.dispatchEvent(new CustomEvent("editor-comm-ready"));
  },

  updated() {
    // Re-register the hook if the element is updated
    EditorComm.setHook(this);
  },

  disconnected() {
    // Clean up event listeners and references when disconnected
    document.removeEventListener(
      "haimeda:selection-entity-update",
      this.selectionEntityHandler
    );

    if (window.editorCommHook === this) {
      delete window.editorCommHook;
    }

    console.log("EditorCommunicationHook disconnected:", this.el.id);
  },
};

export default {
  EditorCommunicationHook,
};

export { EditorHooks };
