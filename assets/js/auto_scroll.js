// Auto-scroll utility for LiveView components

function scrollToBottom(elementId) {
  const element = document.getElementById(elementId);
  if (element) {
    element.scrollTop = element.scrollHeight;
  }
}

window.initAutoScroll = function () {
  // Scroll both containers to bottom
  scrollToBottom("log-content");
  scrollToBottom("chat-messages");
};

// Run on DOMContentLoaded
document.addEventListener("DOMContentLoaded", () => {
  setTimeout(window.initAutoScroll, 0);
});

// Run after every LiveView update (phx:update)
window.addEventListener("phx:update", () => {
  setTimeout(window.initAutoScroll, 0);
});
