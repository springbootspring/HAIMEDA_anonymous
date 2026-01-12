// Editor page specific JavaScript hooks
const EditorHooks = {
  // Add hook for handling page unload events
  BeforeUnload: {
    mounted() {
      window.addEventListener("beforeunload", (e) => {
        // Notify the LiveView that we're about to leave
        this.pushEvent("save-before-unload", {});

        // Allow the browser to show a confirmation dialog
        // Note: Modern browsers ignore custom messages for security reasons
        e.preventDefault();
        e.returnValue = ""; // Chrome requires returnValue to be set
      });
    },
    destroyed() {
      // Clean up the event listener when the component is removed
      window.removeEventListener("beforeunload", null);
    },
  },
};

export default EditorHooks;
