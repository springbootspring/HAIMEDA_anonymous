/**
 * TipTap Loader - Utility to ensure TipTap libraries are loaded
 * This handles dynamic loading of TipTap dependencies if they're not already available
 */

// List of required TipTap scripts - UPDATED paths to match Phoenix structure
const TIPTAP_SCRIPTS = [
  "/assets/tiptap-bundle.js", // Main TipTap bundle
  "/assets/tiptap-extensions.js", // Extensions bundle
];

// Track loading state
let isLoading = false;
let isLoaded = false;
let loadPromise = null;
let callbacks = [];

/**
 * Check if TipTap is available in the global scope
 */
function isTipTapAvailable() {
  return window.TipTap && window.TipTap.Editor;
}

/**
 * Load a script asynchronously
 */
function loadScript(src) {
  return new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = src;
    script.async = true;
    script.onload = () => resolve();
    script.onerror = (err) =>
      reject(new Error(`Failed to load script: ${src}`));
    document.head.appendChild(script);
  });
}

/**
 * Load all TipTap scripts
 */
function loadTipTapScripts() {
  if (isLoaded) return Promise.resolve();
  if (loadPromise) return loadPromise;

  isLoading = true;

  // Check if already available in global scope
  if (isTipTapAvailable()) {
    console.log("[TipTap Loader] TipTap already available in global scope");
    isLoaded = true;
    isLoading = false;
    return Promise.resolve();
  }

  console.log("[TipTap Loader] Loading TipTap libraries");
  if (window.logToServer) {
    window.logToServer.info("Loading TipTap libraries dynamically");
  }

  // Create a promise to load all scripts in sequence
  loadPromise = TIPTAP_SCRIPTS.reduce(
    (promise, scriptSrc) =>
      promise.then(() => {
        console.log(`[TipTap Loader] Loading script: ${scriptSrc}`);
        return loadScript(scriptSrc);
      }),
    Promise.resolve()
  )
    .then(() => {
      console.log("[TipTap Loader] All TipTap scripts loaded");
      if (window.logToServer) {
        window.logToServer.info("All TipTap libraries loaded successfully");
      }

      // Check that TipTap is actually available
      if (!isTipTapAvailable()) {
        const error = new Error(
          "TipTap libraries loaded but window.TipTap is not available"
        );
        console.error(error);
        if (window.logToServer) {
          window.logToServer.error(
            "Libraries loaded but TipTap not available",
            {
              error: error.message,
            }
          );
        }
        return Promise.reject(error);
      }

      isLoaded = true;
      isLoading = false;

      // Notify all waiting callbacks
      callbacks.forEach((callback) => callback());
      callbacks = [];

      return Promise.resolve();
    })
    .catch((error) => {
      console.error("[TipTap Loader] Error loading TipTap libraries:", error);
      if (window.logToServer) {
        window.logToServer.error("Error loading TipTap libraries", {
          error: error.message,
        });
      }

      isLoading = false;
      loadPromise = null; // Allow retry
      return Promise.reject(error);
    });

  return loadPromise;
}

/**
 * Ensure TipTap is loaded and available
 * @param {function} callback - Optional callback when loaded
 * @returns {Promise} - Promise that resolves when TipTap is loaded
 */
function ensureTipTapLoaded(callback) {
  if (callback) {
    if (isLoaded) {
      callback();
    } else {
      callbacks.push(callback);
    }
  }

  return loadTipTapScripts();
}

/**
 * Returns current loading state
 */
function getTipTapLoadState() {
  return {
    isLoaded,
    isLoading,
  };
}

// Create the TipTap namespace if it doesn't exist
window.TipTap = window.TipTap || {};

// Export the loader functions
const TipTapLoader = {
  ensureTipTapLoaded,
  isTipTapAvailable,
  getTipTapLoadState,
};

// Add to global scope
window.TipTapLoader = TipTapLoader;

export default TipTapLoader;
