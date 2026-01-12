// File: tip_tap_toolbar.js
// TipTap editor toolbar functionality

/**
 * Creates a simple toolbar for the TipTap editor
 * @param {HTMLElement} container - The container element for the toolbar
 * @param {Editor} editor - The TipTap editor instance
 * @param {boolean} readOnly - Whether the editor is in read-only mode
 */
export function createSimpleToolbar(container, editor, readOnly) {
  if (readOnly) {
    container.style.display = "none";
    return;
  }

  // Clear any existing buttons
  container.innerHTML = "";

  // Define toolbar buttons
  const buttons = [
    { command: "bold", icon: "B", tooltip: "Fett" },
    { command: "italic", icon: "I", tooltip: "Kursiv" },
    { command: "strike", icon: "S", tooltip: "Durchgestrichen" },
    { command: "heading", level: 1, icon: "H1", tooltip: "Überschrift 1" },
    { command: "heading", level: 2, icon: "H2", tooltip: "Überschrift 2" },
    { command: "heading", level: 3, icon: "H3", tooltip: "Überschrift 3" },
    { command: "bulletList", icon: "•", tooltip: "Aufzählung" },
    { command: "orderedList", icon: "1.", tooltip: "Nummerierte Liste" },
    { command: "paragraph", icon: "¶", tooltip: "Paragraph" },
    { command: "undo", icon: "↩", tooltip: "Rückgängig" },
    { command: "redo", icon: "↪", tooltip: "Wiederholen" },
  ];

  // Create and add buttons
  buttons.forEach((btn) => {
    const button = document.createElement("button");
    button.innerHTML = btn.icon;
    button.title = btn.tooltip;
    button.classList.add("tiptap-toolbar-btn");
    button.dataset.command = btn.command;

    if (btn.level) {
      button.dataset.level = btn.level;
    }

    button.addEventListener("click", () => {
      if (!editor) return;

      // Handle different command types
      switch (btn.command) {
        case "bold":
          editor.chain().focus().toggleBold().run();
          break;
        case "italic":
          editor.chain().focus().toggleItalic().run();
          break;
        case "strike":
          editor.chain().focus().toggleStrike().run();
          break;
        case "heading":
          editor.chain().focus().toggleHeading({ level: btn.level }).run();
          break;
        case "bulletList":
          editor.chain().focus().toggleBulletList().run();
          break;
        case "orderedList":
          editor.chain().focus().toggleOrderedList().run();
          break;
        case "paragraph":
          editor.chain().focus().setParagraph().run();
          break;
        case "undo":
          editor.chain().focus().undo().run();
          break;
        case "redo":
          editor.chain().focus().redo().run();
          break;
        default:
          console.warn(`Unsupported command: ${btn.command}`);
      }
    });

    // Add the button to the toolbar
    container.appendChild(button);
  });

  // Set up active state tracking
  const updateActiveStates = () => {
    if (!editor) return;

    // Update all buttons
    Array.from(container.querySelectorAll(".tiptap-toolbar-btn")).forEach(
      (button) => {
        const command = button.dataset.command;
        const level = button.dataset.level;
        let isActive = false;

        // Determine if this button should be active
        switch (command) {
          case "bold":
            isActive = editor.isActive("bold");
            break;
          case "italic":
            isActive = editor.isActive("italic");
            break;
          case "strike":
            isActive = editor.isActive("strike");
            break;
          case "heading":
            isActive = editor.isActive("heading", { level: parseInt(level) });
            break;
          case "bulletList":
            isActive = editor.isActive("bulletList");
            break;
          case "orderedList":
            isActive = editor.isActive("orderedList");
            break;
          case "paragraph":
            isActive = editor.isActive("paragraph");
            break;
        }

        // Apply active class if needed
        if (isActive) {
          button.classList.add("active");
        } else {
          button.classList.remove("active");
        }
      }
    );
  };

  // Subscribe to editor changes to update button states
  editor.on("selectionUpdate", updateActiveStates);
  editor.on("transaction", updateActiveStates);

  // Initial update
  updateActiveStates();
}

/**
 * Creates a toolbar button and adds it to the toolbar
 * @param {HTMLElement} toolbar - The toolbar element
 * @param {string} text - Button text or icon
 * @param {string} tooltip - Button tooltip text
 * @param {Function} clickHandler - Function to handle click events
 * @param {string} className - Optional additional CSS class
 * @returns {HTMLElement} The created button
 */
export function addToolbarButton(
  toolbar,
  text,
  tooltip,
  clickHandler,
  className = ""
) {
  const button = document.createElement("button");
  button.innerHTML = text;
  button.title = tooltip;
  button.className = `tiptap-toolbar-btn ${className}`;

  button.addEventListener("click", clickHandler);
  toolbar.appendChild(button);

  return button;
}

/**
 * Add an entity toolbar to allow inserting entities
 * @param {HTMLElement} container - The container for the entity toolbar
 * @param {Editor} editor - The TipTap editor instance
 * @param {Function} createEntityCallback - Function to create a new entity
 */
export function addEntityToolbar(container, editor, createEntityCallback) {
  const entityTypes = [
    { name: "person", color: "#ffccaa", label: "Person" },
    { name: "location", color: "#aaccff", label: "Ort" },
    { name: "organization", color: "#ccffaa", label: "Organisation" },
  ];

  // Create toolbar wrapper
  const toolbar = document.createElement("div");
  toolbar.className = "entity-toolbar";

  // Add a label
  const label = document.createElement("span");
  label.textContent = "Neue Entität: ";
  label.className = "entity-toolbar-label";
  toolbar.appendChild(label);

  // Add entity type buttons
  entityTypes.forEach((type) => {
    const button = document.createElement("button");
    button.textContent = type.label;
    button.className = "entity-type-btn";
    button.style.backgroundColor = type.color;

    button.addEventListener("click", () => {
      const { from, to } = editor.state.selection;

      // Only proceed if text is selected
      if (from !== to) {
        const selectedText = editor.state.doc.textBetween(from, to);

        if (selectedText && selectedText.trim()) {
          // Call callback to create entity
          createEntityCallback(selectedText, type.name, type.color);
        }
      } else {
        // Show message to select text first
        showToolbarMessage(toolbar, "Bitte zuerst Text markieren");
      }
    });

    toolbar.appendChild(button);
  });

  // Add message container for feedback
  const messageEl = document.createElement("span");
  messageEl.className = "entity-toolbar-message";
  toolbar.appendChild(messageEl);

  // Add the toolbar to the container
  container.appendChild(toolbar);
}

/**
 * Shows a message in the entity toolbar
 * @param {HTMLElement} toolbar - The entity toolbar
 * @param {string} message - The message to display
 */
function showToolbarMessage(toolbar, message) {
  const messageEl = toolbar.querySelector(".entity-toolbar-message");
  if (messageEl) {
    messageEl.textContent = message;
    messageEl.style.opacity = "1";

    // Hide after a delay
    setTimeout(() => {
      messageEl.style.opacity = "0";
    }, 2000);
  }
}
