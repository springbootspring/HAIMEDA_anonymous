export const LogContainer = {
  mounted() {
    this.scrollToBottom();

    this.handleEvent("scroll-log-bottom", () => {
      this.scrollToBottom();
    });
  },
  updated() {
    this.scrollToBottom();
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight;
  },
};
