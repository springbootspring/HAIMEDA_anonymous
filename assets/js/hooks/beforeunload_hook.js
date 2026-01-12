const BeforeUnloadHook = {
  BeforeUnload: {
    mounted() {
      // Add beforeunload event listener to prompt user when closing tab
      window.addEventListener("beforeunload", (e) => {
        // Show warning if there are unsaved changes
        const confirmationMessage =
          "Einige Änderungen sind möglicherweise nicht gespeichert. Wirklich verlassen?";

        // Most modern browsers ignore this message but still require setting returnValue
        e.returnValue = confirmationMessage;
        return confirmationMessage;
      });
    },
  },
};

export default BeforeUnloadHook;
