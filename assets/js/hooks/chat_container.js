export const ChatContainer = {
  mounted() {
    console.log("ChatContainer mounted");
    this.scrollToBottom();

    // Handle custom events sent from LiveView
    this.handleEvent("scroll-chat-bottom", () => {
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
