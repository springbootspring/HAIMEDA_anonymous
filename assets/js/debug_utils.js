/**
 * Debug utilities for sending JavaScript logs to Elixir server
 */

// Log levels matching common console methods
const LOG_LEVELS = {
  LOG: "log",
  INFO: "info",
  WARN: "warn",
  ERROR: "error",
  DEBUG: "debug",
};

// Simple logging for startup issues (before the debug system is online)
const startupLogs = [];
function captureStartupLog(message, level = "log") {
  startupLogs.push({ message, level, timestamp: new Date().toISOString() });
  console[level](`[STARTUP] ${message}`);
}

/**
 * Initialize debug logging to server
 * @param {Object} liveSocket - The Phoenix LiveSocket instance
 */
export function initServerLogging(liveSocket) {
  captureStartupLog("Initializing server logging system", "info");

  // Direct console methods that will send to server
  const serverLog =
    (level) =>
    (message, ...args) => {
      // Always log to console first
      console[level](`[SERVER] ${message}`, ...args);

      if (!window.elixirDebug?.pushEventToServer) {
        console.warn("Server logging not fully initialized yet!");
        return;
      }

      // Extract metadata from args - use first object if present
      const metadata =
        args.find((arg) => typeof arg === "object" && arg !== null) || {};

      try {
        window.elixirDebug.pushEventToServer("js_debug", {
          message: message,
          level: level,
          timestamp: new Date().toISOString(),
          metadata: JSON.parse(JSON.stringify(metadata)), // Ensure serializable
          url: window.location.href,
          userAgent: navigator.userAgent,
        });
      } catch (e) {
        console.error("Failed to send log to server:", e);
      }
    };

  // Store the liveSocket instance for use in logging functions
  window.elixirDebug = {
    liveSocket,
    enabled: true,
    hookInstance: null,

    // Methods to find and use the debug hook
    findHook() {
      captureStartupLog("Looking for debug hook...");
      // First try to find the hook directly
      const debugElement = document.querySelector('[phx-hook="DebugHook"]');
      if (debugElement) {
        captureStartupLog(
          `Found debug hook element: ${debugElement.id}`,
          "info"
        );
        return true;
      }

      // If hook element not found, return false
      captureStartupLog("Debug hook element not found!", "warn");
      return false;
    },

    pushEventToServer(event, payload) {
      // Find the hook instance if we don't have one yet
      if (!this.hookInstance) {
        // Only continue with caution if we've found the hook element
        if (this.findHook()) {
          captureStartupLog(
            "No hook instance yet, but element exists. Will try again later."
          );
        } else {
          // Log the error more visibly
          console.error(
            "COMMUNICATION ERROR: Cannot send events to server - debug hook not found!"
          );
          return false;
        }
      }

      // If we have a hook instance, use it
      if (this.hookInstance) {
        try {
          this.hookInstance.pushEvent(event, payload);
          return true;
        } catch (e) {
          console.error("Error pushing event to server:", e);
          return false;
        }
      }

      return false;
    },

    // Direct logging methods that send to server
    log: serverLog(LOG_LEVELS.LOG),
    info: serverLog(LOG_LEVELS.INFO),
    warn: serverLog(LOG_LEVELS.WARN),
    error: serverLog(LOG_LEVELS.ERROR),
    debug: serverLog(LOG_LEVELS.DEBUG),

    // Method to enable/disable server logging
    setEnabled(enabled) {
      this.enabled = enabled;
      console.log(`Server logging ${enabled ? "enabled" : "disabled"}`);
    },

    // Method to send all startup logs to server once connected
    sendStartupLogs() {
      if (startupLogs.length > 0) {
        captureStartupLog(
          `Sending ${startupLogs.length} startup logs to server`,
          "info"
        );

        startupLogs.forEach((log) => {
          this[log.level || "log"](`[STARTUP] ${log.message}`, {
            timestamp: log.timestamp,
          });
        });

        // Clear startup logs after sending
        startupLogs.length = 0;
      }
    },
  };

  // Add a window event listener to receive state from the server
  window.addEventListener("phx:state", (e) => {
    if (window.elixirDebug && window.elixirDebug.enabled) {
      console.log("Received state from server:", e.detail);
      // Store the state for debugging purposes
      window.elixirDebug.currentState = e.detail;
    }
  });

  // Add global helpers for direct logging from the console
  window.logToServer = {
    log: (...args) => window.elixirDebug.log(...args),
    info: (...args) => window.elixirDebug.info(...args),
    warn: (...args) => window.elixirDebug.warn(...args),
    error: (...args) => window.elixirDebug.error(...args),
    debug: (...args) => window.elixirDebug.debug(...args),
  };

  captureStartupLog("Debug system initialized - waiting for hooks to mount");

  // Try to find the hook element immediately
  window.elixirDebug.findHook();
}

/**
 * Create a debug hook that can be used in LiveView components
 */
export const DebugHook = {
  mounted() {
    console.log(`DebugHook mounted on element #${this.el.id}`);

    // Register this hook for server logging
    if (window.elixirDebug) {
      window.elixirDebug.hookInstance = this;

      // Send an initial log to confirm connectivity
      setTimeout(() => {
        window.elixirDebug.info(
          `DebugHook connected successfully on #${this.el.id}`,
          {
            elementId: this.el.id,
            hookName: "DebugHook",
          }
        );

        // Send any startup logs
        window.elixirDebug.sendStartupLogs();
      }, 100);
    } else {
      console.error(
        "window.elixirDebug not initialized before DebugHook mounted!"
      );
    }

    // Handle state pushes from the server
    this.handleEvent("state", (payload) => {
      console.log("Received state:", payload);
      if (window.elixirDebug) {
        window.elixirDebug.currentState = payload;
      }

      // Dispatch an event that other parts of the application can listen for
      window.dispatchEvent(new CustomEvent("phx:state", { detail: payload }));
    });
  },

  updated() {
    console.log(`DebugHook updated on element #${this.el.id}`);
  },

  destroyed() {
    console.log(`DebugHook destroyed on element #${this.el.id}`);

    // Unregister this hook when removed
    if (window.elixirDebug && window.elixirDebug.hookInstance === this) {
      window.elixirDebug.hookInstance = null;
      console.warn(
        "DebugHook unregistered - server logging will stop working!"
      );
    }
  },
};
