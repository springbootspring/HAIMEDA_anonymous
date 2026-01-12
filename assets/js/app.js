// Import hooks
import HooksFromFile from "./hooks.js";

import { ChatContainer } from "./hooks/chat_container";
import { LogContainer } from "./hooks/log_container";
import { SelectChangeHook } from "./hooks/select_change_hook";
import { ChatInputHistory } from "./hooks/chat_input_history";
// import BeforeUnloadHook from "./hooks/beforeunload_hook.js";
import WindowHooks from "./hooks/window_hooks.js";
import TipTapEditor from "./tiptap/tip_tap_editor.js";
import * as EditorComm from "./editor_comm.js";
import { EditorCommunicationHook } from "./hooks/editor_hooks.js"; // Import the communication hook
// Import debug utilities
import { initServerLogging, DebugHook } from "./debug_utils.js";

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons
import "phoenix_html";
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import topbar from "../vendor/topbar.js";
import "./auto_scroll.js";

// Import window-specific code
// import "./window.js";

// Define hooks
let Hooks = {
  ChatContainer,
  LogContainer,
  SelectChangeHook,
  ChatInputHistory,
  TipTapEditor,
  ...HooksFromFile,
  ...WindowHooks,
  // Add the debug hook with explicit name
  DebugHook: DebugHook,
  // Register the communication hook
  EditorCommunicationHook: EditorCommunicationHook,
};

// Log the hooks for debugging
console.log("Registered hooks:", Object.keys(Hooks));

let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

let liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: Hooks,
  dom: {
    onBeforeElUpdated(from, to) {
      if (from._x_dataStack) {
        window.Alpine.clone(from, to);
      }
    },
  },
});

// Initialize server logging with our LiveSocket
initServerLogging(liveSocket);

// Add EditorComm to the window for global access with debug logging
window.EditorComm = {
  ...EditorComm,
  // Override pushEvent with debug
  pushEvent: (event, payload) => {
    console.log(`EditorComm: Pushing event '${event}' with payload:`, payload);
    if (EditorComm.pushEvent) {
      return EditorComm.pushEvent(event, payload);
    } else {
      console.error("EditorComm.pushEvent not properly initialized");
      return false;
    }
  },
};

// Add a global debug function to set chat input value
window.setChatInputValue = function (value) {
  if (window.chatHistoryHook) {
    console.log("Setting chat input value via global function:", value);
    window.chatHistoryHook.setValueDirectly(value);
    return true;
  } else {
    console.error("Chat history hook not available");
    return false;
  }
};

// Expose a function to query all Phoenix hooks for debugging
window.getPhoenixHooks = function () {
  if (window.liveSocket) {
    return Array.from(document.querySelectorAll("[phx-hook]")).map((el) => ({
      id: el.id,
      hook: el.getAttribute("phx-hook"),
      element: el,
    }));
  } else {
    return "LiveSocket not initialized";
  }
};

// Function to scroll an element to the bottom
function scrollToBottomById(elementId) {
  const element = document.getElementById(elementId);
  if (element) {
    element.scrollTop = element.scrollHeight;
  }
}

// Store previous scroll heights to detect changes
let prevScrollHeights = {
  "log-content": 0,
  "chat-messages": 0,
};

// Listen for LiveView updates
window.addEventListener("phx:update", () => {
  const logContent = document.getElementById("log-content");
  const chatMessages = document.getElementById("chat-messages");
  const threshold = 50; // Pixels from bottom to trigger auto-scroll

  if (logContent) {
    const nearBottom =
      logContent.scrollHeight - logContent.scrollTop - logContent.clientHeight <
      threshold;
    const contentChanged =
      logContent.scrollHeight > prevScrollHeights["log-content"];

    // Scroll if near bottom AND content height increased
    if (nearBottom && contentChanged) {
      // Use setTimeout to ensure DOM is fully patched
      setTimeout(() => scrollToBottomById("log-content"), 0);
    }
    // Update previous scroll height *after* potential scroll
    prevScrollHeights["log-content"] = logContent.scrollHeight;
  }

  if (chatMessages) {
    const nearBottom =
      chatMessages.scrollHeight -
        chatMessages.scrollTop -
        chatMessages.clientHeight <
      threshold;
    const contentChanged =
      chatMessages.scrollHeight > prevScrollHeights["chat-messages"];

    // Scroll if near bottom AND content height increased
    if (nearBottom && contentChanged) {
      // Use setTimeout to ensure DOM is fully patched
      setTimeout(() => scrollToBottomById("chat-messages"), 0);
    }
    // Update previous scroll height *after* potential scroll
    prevScrollHeights["chat-messages"] = chatMessages.scrollHeight;
  }
});

// When receiving custom updates from LiveView
window.addEventListener("phx:editor_content_update", (e) => {
  const { editorId, content, formattedContent } = e.detail;
  console.log(`Received update for editor ${editorId}`);
  EditorComm.forceRefreshEditor(editorId, content, formattedContent);
});

// Enhanced event handler for editor refreshes with better debugging
window.addEventListener("phx:force_refresh_editor", (e) => {
  // Extract data with better error handling
  try {
    const { tab_id, content, formatted_content, refresh_key } = e.detail;
    console.log(
      `Forced editor refresh for tab ${tab_id} (key: ${refresh_key})`
    );

    // Try different methods to ensure the refresh happens

    // Method 1: Use EditorComm if available
    if (
      window.EditorComm &&
      typeof window.EditorComm.forceRefreshEditor === "function"
    ) {
      console.log("Refreshing editor via EditorComm");
      window.EditorComm.forceRefreshEditor(
        `tiptap-editor-${tab_id}`,
        content,
        formatted_content
      );
      return;
    }

    // Method 2: Find the editor element and update it directly
    const editorElem = document.getElementById(`tiptap-editor-${tab_id}`);
    if (
      editorElem &&
      editorElem._component &&
      typeof editorElem._component.updateContent === "function"
    ) {
      console.log("Refreshing editor via direct component access");
      editorElem._component.updateContent(content, formatted_content);
      return;
    }

    // Method 3: Find any editor hook and push an event
    const editorHooks = document.querySelectorAll('[phx-hook="TipTapEditor"]');
    for (const hook of editorHooks) {
      if (hook && hook.id === `tiptap-editor-${tab_id}` && hook._phxHook) {
        console.log("Refreshing editor via hook event");
        hook._phxHook.pushEventTo(`#${hook.id}`, "update_editor_content", {
          content: content,
          formatted_content: formatted_content,
        });
        return;
      }
    }

    // Last resort: Force a page reload if nothing else worked and this is a critical update
    console.warn(
      "Could not find a way to refresh the editor, consider implementing a fallback"
    );
  } catch (error) {
    console.error("Error during forced editor refresh:", error);
  }
});

// Enhanced event handler specifically for refreshing after content save
window.addEventListener("phx:force_editor_refresh_after_save", (e) => {
  try {
    const {
      editor_id,
      tab_id,
      content,
      formatted_content,
      refresh_key,
      full_refresh,
    } = e.detail;
    console.log(
      `Force editor refresh after save for ${editor_id} with key ${refresh_key}`
    );

    // Get the editor element directly
    const editorElem = document.getElementById(editor_id);
    if (!editorElem) {
      console.error(`Could not find editor element with ID: ${editor_id}`);
      return;
    }

    // Try to find the hook or component on the element
    if (editorElem._phxHook) {
      console.log(`Found hook on editor element, forcing refresh`);

      // Call the special full refresh method if it exists
      if (typeof editorElem._phxHook.forceFullRefresh === "function") {
        console.log(`Calling forceFullRefresh on hook`);
        editorElem._phxHook.forceFullRefresh(content, formatted_content);
        return;
      }

      // Fall back to regular update event
      editorElem._phxHook.pushEventTo(
        `#${editor_id}`,
        "update_editor_content",
        {
          content: content,
          formatted_content: formatted_content,
          full_refresh: true,
        }
      );
      return;
    }

    // If hook not found, try other methods
    if (
      window.EditorComm &&
      typeof window.EditorComm.forceRefreshEditor === "function"
    ) {
      console.log(`Using EditorComm.forceRefreshEditor as fallback`);
      window.EditorComm.forceRefreshEditor(
        editor_id,
        content,
        formatted_content,
        true
      );
      return;
    }

    // Last resort - try to trigger a page navigation event to force complete refresh
    if (full_refresh) {
      console.warn(`No editor hook found, using fallback refresh method`);
      // Dispatch custom event that can be captured anywhere in the code
      window.dispatchEvent(
        new CustomEvent("haimeda:force-editor-refresh", {
          bubbles: true,
          detail: { editor_id, content, formatted_content },
        })
      );
    }
  } catch (error) {
    console.error("Error during forced editor refresh after save:", error);
  }
});

// Initial scroll on load
document.addEventListener("DOMContentLoaded", () => {
  // Use setTimeout to ensure initial render is complete
  setTimeout(() => {
    const logContent = document.getElementById("log-content");
    const chatMessages = document.getElementById("chat-messages");
    if (logContent) {
      scrollToBottomById("log-content");
      prevScrollHeights["log-content"] = logContent.scrollHeight;
    }
    if (chatMessages) {
      scrollToBottomById("chat-messages");
      prevScrollHeights["chat-messages"] = chatMessages.scrollHeight;
    }
  }, 50); // Small delay for initial render
});

// Show progress bar on live navigation and form submits
topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" });
window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300));
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide());

// Handle window control events
window.addEventListener("window:minimize", () => {
  if (window.desktop) {
    window.desktop.minimize();
  }
});

window.addEventListener("window:maximize", () => {
  if (window.desktop) {
    window.desktop.isMaximized()
      ? window.desktop.unmaximize()
      : window.desktop.maximize();
  }
});

window.addEventListener("window:close", () => {
  if (window.desktop) {
    window.desktop.close();
  }
});

// connect if there are any LiveViews on the page
liveSocket.connect();

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket;

// Add test logs with increasing delay to ensure initialization completes
setTimeout(() => {
  console.log("Executing test logs...");

  // Test if the debug element exists
  const debugElement = document.querySelector('[phx-hook="DebugHook"]');
  console.log("Debug element found:", !!debugElement, debugElement?.id);

  if (window.elixirDebug) {
    // Test direct logging
    window.elixirDebug.info("Test 1: Initial startup message", {
      timestamp: new Date().toISOString(),
    });

    // Test the window.logToServer convenience method
    if (window.logToServer) {
      window.logToServer.warn(
        "Test 2: Using window.logToServer convenience method"
      );
    }
  } else {
    console.error("window.elixirDebug not initialized after 1000ms!");
  }
}, 1000);

// Add another test with longer delay to catch slow initializations
setTimeout(() => {
  if (window.elixirDebug) {
    window.elixirDebug.debug("Test 3: Debug logging after longer delay");

    // Log the hook status
    window.elixirDebug.info("Hook status", {
      hookInstance: !!window.elixirDebug.hookInstance,
      enabled: window.elixirDebug.enabled,
    });
  }
}, 3000);
