export const ChatInputSync = {
  mounted() {
    console.log("ChatInputSync hook mounted");

    // This handles any direct value changes from LiveView
    this.handleEvent("sync_input_value", ({ value }) => {
      console.log("Syncing input value:", value);
      this.el.value = value;

      // Move cursor to end of input for better UX
      this.el.focus();
      this.el.selectionStart = this.el.selectionEnd = this.el.value.length;
    });
  },

  updated() {
    // This ensures the input stays in sync with LiveView state
    if (this.el.value !== this.el.getAttribute("value")) {
      this.el.value = this.el.getAttribute("value");
    }
  },
};
