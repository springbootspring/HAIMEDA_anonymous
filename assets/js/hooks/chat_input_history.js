export const ChatInputHistory = {
  mounted() {
    console.log("ChatInputHistory hook mounted");

    // Watch for changes to the input value from the server
    this.handleEvent("sync_input_value", ({ value }) => {
      console.log("Syncing input value:", value);
      this.el.value = value;

      // Move cursor to end
      this.el.focus();
      this.el.selectionStart = this.el.selectionEnd = this.el.value.length;
    });
  },

  updated() {
    // This ensures the DOM value stays in sync with the LiveView assigns
    const newValue = this.el.getAttribute("value");
    if (this.el.value !== newValue) {
      console.log("Updating input value from attribute:", newValue);
      this.el.value = newValue;

      // Move cursor to end
      this.el.focus();
      this.el.selectionStart = this.el.selectionEnd = this.el.value.length;
    }
  },
};
