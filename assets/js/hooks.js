import { ChatInputSync } from "./hooks/chat_input_sync";

const Hooks = {};

// Hook for handling sidebar section items
Hooks.SidebarHandler = {
  mounted() {
    console.log("SidebarHandler mounted");
    // We don't need special event handling for delete buttons anymore
    // The LiveView form handling takes care of it
  },
};

// Hook for scrolling chat to the bottom when messages are added
Hooks.ChatScroll = {
  mounted() {
    this.scrollToBottom();
  },
  updated() {
    this.scrollToBottom();
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight;
  },
};

// Register ChatInputSync hook
Hooks.ChatInputSync = ChatInputSync;

// Export the Hooks object
export default Hooks;
