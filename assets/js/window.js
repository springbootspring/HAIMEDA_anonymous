// Add this file to handle desktop window specifics

// Set document background to dark when loaded
document.addEventListener("DOMContentLoaded", () => {
  // Apply dark mode to document
  document.documentElement.style.backgroundColor = "#222222";
  document.body.style.backgroundColor = "#222222";

  // Check if running in desktop mode
  if (window.desktop) {
    // Apply dark theme to desktop window
    window.desktop.setBackgroundColor("#222222");

    // On Windows, try to set the app theme to dark
    if (window.desktop.platform === "win32") {
      window.desktop.setWindowAppearance("dark");
    }
  }
});
