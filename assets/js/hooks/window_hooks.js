const WindowHooks = {
  mounted() {
    // Add event listeners for window controls if needed
    document.querySelectorAll(".titlebar-button").forEach((button) => {
      button.addEventListener("click", (e) => {
        const action = e.target.closest(".titlebar-button").dataset.action;

        if (action === "close") {
          window.desktopAPI.close();
        } else if (action === "minimize") {
          window.desktopAPI.minimize();
        } else if (action === "maximize") {
          window.desktopAPI.toggleMaximize();
        }
      });
    });
  },
};

export default WindowHooks;
