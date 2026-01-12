// File: tip_tap_editor.js
// Main entry point for the TipTap editor
// This file imports and re-exports functionality from the modular components

import TipTapEditor from "./tip_tap_core.js";
import { ColoredEntity } from "./tip_tap_entities.js";
import * as TipTapUtils from "./tip_tap_utils.js";
import * as TipTapToolbar from "./tip_tap_toolbar.js";
import { SelectionList } from "./selection_list.js"; // Ensure the import is correct

// Improved handling for editor content refreshes
const enhancedTipTapEditor = {
  ...TipTapEditor,

  // Enhanced mounted to add extra robustness to event handling
  mounted() {
    // Call original mounted method
    TipTapEditor.mounted.call(this);

    // Track initialization state
    this.editorInitialized = false;
    this.loadingTimeout = null;

    // Set a timeout to ensure the loading overlay is hidden eventually
    this.loadingTimeout = setTimeout(() => {
      this.hideLoadingOverlay();
    }, 10000); // 10 seconds max loading time

    // Monitor for paste events on the document to ensure we catch them
    document.addEventListener("paste", (e) => {
      if (this.editor && this.el.contains(e.target)) {
        // If we're pasting into our editor, ensure content is saved
        setTimeout(() => {
          if (this.editor) {
            const json = this.editor.getJSON();
            const text = this.editor.getText();

            // Force content update to be sent to server
            this.pushEvent("content-updated", {
              content: text,
              formatted_content: JSON.stringify(json),
              persist_entities: true,
            });

            window.elixirDebug?.info(
              "Document paste event detected in editor, saving content"
            );
          }
        }, 100);
      }
    });

    // When a TipTap editor is initialized with selection lists,
    // listen for the initialization event and force a refresh
    this.el.addEventListener("tiptap-editor-initialized", (e) => {
      if (e.detail && e.detail.hasSelectionLists) {
        window.elixirDebug.info(
          "Editor initialized with selection lists, performing verification refresh"
        );
        setTimeout(() => {
          if (this.editor) {
            const content = this.el.getAttribute("data-content");
            const formattedContent = this.el.getAttribute(
              "data-formatted-content"
            );
            this.forceRefreshEditor(content, formattedContent);
          }
        }, 500);
      }
    });

    // Add enhanced event handler for forced refreshes
    this.handleEvent("force_refresh_editor", (payload) => {
      const tabId = this.el.getAttribute("data-tab-id");

      window.elixirDebug.info(
        `Tab ${tabId} received force_refresh_editor event: ${
          payload.content?.length || 0
        }, ${payload.formatted_content?.length || 0}`
      );

      // If the event is for this tab, force refresh immediately
      if (!payload.tab_id || payload.tab_id === tabId) {
        // Use a timeout to ensure DOM updates have completed
        setTimeout(() => {
          if (this.editor) {
            this.forceRefreshEditor(payload.content, payload.formatted_content);
            // Ensure the loading overlay is hidden after refresh
            this.hideLoadingOverlay();
          } else {
            window.elixirDebug.info(
              `Editor not initialized yet for tab ${tabId}, saving for later`
            );
            this.pendingContent = payload.content;
            this.pendingFormattedContent = payload.formatted_content;
            // Re-initialize the editor
            this.initEditor();
          }
        }, 20);
      }
    });

    // Add special handler for the force refresh after save event
    this.handleEvent(
      "update_editor_content",
      ({ content, formatted_content, full_refresh }) => {
        console.log(
          `TipTapEditor received update_editor_content event with full_refresh=${full_refresh}`
        );

        if (full_refresh) {
          // For a full refresh, we need to completely reinitialize the editor
          this.forceFullRefresh(content, formatted_content);
        } else {
          // Regular update
          this.updateContent(content, formatted_content);
        }
      }
    );

    // Listen for global refresh events as well
    window.addEventListener("haimeda:force-editor-refresh", (event) => {
      if (event.detail.editor_id === this.el.id) {
        console.log(`Received global force refresh event for ${this.el.id}`);
        this.forceFullRefresh(
          event.detail.content,
          event.detail.formatted_content
        );
      }
    });

    // Listen for selection list events
    this.el.addEventListener("haimeda:selection-entity-update", (event) => {
      console.log(
        "TipTapEditor received selection-entity-update:",
        event.detail
      );
      // Forward to LiveView
      this.pushEvent("selection-entity-update", event.detail);
    });
  },

  // Add method to hide loading overlay
  hideLoadingOverlay() {
    const loadingOverlay = this.el.querySelector(".tiptap-loading-overlay");
    if (loadingOverlay) {
      loadingOverlay.classList.add("hidden");

      // After the animation completes, we can remove it entirely
      setTimeout(() => {
        loadingOverlay.style.display = "none";
      }, 500);
    }

    // Clear the timeout if it exists
    if (this.loadingTimeout) {
      clearTimeout(this.loadingTimeout);
      this.loadingTimeout = null;
    }

    // Mark editor as initialized
    this.editorInitialized = true;
  },

  // Override the initEditor method to add loading state handling
  initEditor() {
    // First let's call the original initEditor
    TipTapEditor.initEditor.call(this);

    // Apply deletion styling to ensure deleted entities are properly styled
    if (this.editor) {
      // Check if there are selection lists that need to be properly rendered
      const checkSelectionLists = () => {
        const containerEl = this.el.querySelector(".tiptap-content");
        const selectionLists = containerEl?.querySelectorAll(
          ".selection-list-container"
        );

        if (selectionLists && selectionLists.length > 0) {
          window.elixirDebug.info(
            `Found ${selectionLists.length} selection lists, ensuring they're rendered`
          );

          // Give a short delay to ensure they're fully rendered
          setTimeout(() => {
            this.hideLoadingOverlay();
          }, 300);
        } else {
          // No selection lists, we can hide the loading overlay
          this.hideLoadingOverlay();
        }
      };

      // Apply entity deletion styling with retry to ensure it works
      if (typeof this.applyDeletionStylingWithRetry === "function") {
        setTimeout(() => {
          this.applyDeletionStylingWithRetry(3);
          console.log("Applied deletion styling during initialization");
        }, 100);
      } else if (typeof this.applyDeletionStyling === "function") {
        setTimeout(() => {
          this.applyDeletionStyling();
          console.log("Applied deletion styling during initialization");
        }, 100);
      }

      // Check after a short delay to ensure the DOM has updated
      setTimeout(checkSelectionLists, 500);

      // Also set up observers to detect when selection lists are added to the DOM
      const observer = new MutationObserver((mutations) => {
        for (const mutation of mutations) {
          if (mutation.addedNodes.length) {
            const hasSelectionList = Array.from(mutation.addedNodes).some(
              (node) =>
                node.classList &&
                node.classList.contains("selection-list-container")
            );

            if (hasSelectionList) {
              window.elixirDebug.info(
                "Selection list added to DOM, ensuring it's rendered"
              );
              setTimeout(() => this.hideLoadingOverlay(), 200);
              break;
            }
          }
        }
      });

      observer.observe(this.el.querySelector(".tiptap-content"), {
        childList: true,
        subtree: true,
      });
    }
  },

  // Override forceRefreshEditor to ensure loading state is handled
  forceRefreshEditor(content, formattedContentStr) {
    // First show loading overlay when refreshing
    const loadingOverlay = this.el.querySelector(".tiptap-loading-overlay");
    if (loadingOverlay) {
      loadingOverlay.style.display = "flex";
      loadingOverlay.classList.remove("hidden");
    }

    // Call the original implementation
    TipTapEditor.forceRefreshEditor.call(this, content, formattedContentStr);

    // Apply entity deletion styling with retry to ensure it works after refresh
    if (typeof this.applyDeletionStylingWithRetry === "function") {
      setTimeout(() => {
        this.applyDeletionStylingWithRetry(3);
        console.log("Applied deletion styling after refresh");
      }, 300);
    } else if (typeof this.applyDeletionStyling === "function") {
      setTimeout(() => {
        this.applyDeletionStyling();
        console.log("Applied deletion styling after refresh");
      }, 300);
    }

    // Set a timeout to hide loading overlay after refresh is complete
    setTimeout(() => {
      this.hideLoadingOverlay();
    }, 800); // Give it a bit more time to render fully
  },

  // Add a method to force a full editor refresh
  forceFullRefresh(content, formattedContent) {
    console.log(
      `Performing full editor refresh with content: ${content?.substring(
        0,
        50
      )}...`
    );

    try {
      // Parse the formatted content if it's a string
      let parsedContent = formattedContent;
      if (typeof formattedContent === "string") {
        try {
          parsedContent = JSON.parse(formattedContent);
        } catch (e) {
          console.error("Failed to parse formatted content:", e);
          // Create basic document structure with the content
          parsedContent = {
            type: "doc",
            content: [
              {
                type: "paragraph",
                content: [{ type: "text", text: content || "" }],
              },
            ],
          };
        }
      }

      // First store references to current editor state we want to preserve
      const wasEditable = this.editor?.isEditable || false;

      // Completely destroy and recreate the editor
      if (this.editor) {
        console.log("Destroying existing editor instance");
        this.editor.destroy();
        this.editor = null;
      }

      // Wait a tiny bit to ensure DOM is ready
      setTimeout(() => {
        // Reinitialize the editor with the new content
        console.log("Reinitializing editor with fresh content");
        this.initTipTap(content, parsedContent);

        // Restore editor state
        if (!wasEditable) {
          this.editor.setEditable(false);
        }

        // Apply deletion styling after initialization
        if (typeof this.applyDeletionStylingWithRetry === "function") {
          setTimeout(() => {
            this.applyDeletionStylingWithRetry(3);
            console.log("Applied deletion styling after full refresh");
          }, 300);
        } else if (typeof this.applyDeletionStyling === "function") {
          setTimeout(() => {
            this.applyDeletionStyling();
            console.log("Applied deletion styling after full refresh");
          }, 300);
        }

        // Show success message in console
        console.log("Editor successfully refreshed");

        // Dispatch event to notify other components that editor was refreshed
        window.dispatchEvent(
          new CustomEvent("editor-refreshed", {
            detail: { editorId: this.el.id },
          })
        );
      }, 50);
    } catch (e) {
      console.error("Error during full editor refresh:", e);
    }
  },
};

// Re-export enhanced editor hook for use in the Phoenix LiveView
export default enhancedTipTapEditor;

// Re-export utility functions and components for external use
export { ColoredEntity, SelectionList, TipTapUtils, TipTapToolbar };
