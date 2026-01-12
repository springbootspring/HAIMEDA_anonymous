// File: tip_tap_core.js
// Core functionality for TipTap editor setup and initialization
import { Editor } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";
import Placeholder from "@tiptap/extension-placeholder";

import { ColoredEntity } from "./tip_tap_entities.js";
import { createSimpleToolbar } from "./tip_tap_toolbar.js";
import {
  ensureEntitiesRender,
  ensureEntityTextMatches,
  sanitizeFormattedContent,
} from "./tip_tap_utils.js";
import { SelectionList } from "./selection_list.js";

// Add this function to help debug hardBreak preservation
export function verifyHardBreakPreservation(docContent) {
  let hardBreakCount = 0;

  // Only process valid content
  if (
    !docContent ||
    !docContent.content ||
    !Array.isArray(docContent.content)
  ) {
    window.elixirDebug.info(
      "Invalid document structure for hardBreak verification"
    );
    return 0;
  }

  // Count hardBreak nodes at all levels
  docContent.content.forEach((block) => {
    if (block.content && Array.isArray(block.content)) {
      block.content.forEach((node) => {
        if (node.type === "hardBreak") {
          hardBreakCount++;
          window.elixirDebug.info("Found hardBreak node:", node);
        }
      });
    }
  });

  window.elixirDebug.info(
    `Document contains ${hardBreakCount} hardBreak nodes`
  );
  return hardBreakCount;
}

export function createBasicTipTapEditor(element, options = {}) {
  try {
    // Process initial content to check hardBreaks
    if (options.content && typeof options.content === "object") {
      window.elixirDebug.info(
        "Initial content hardBreak count:",
        verifyHardBreakPreservation(options.content)
      );
    }

    // Check content for selection lists before editor creation
    let hasSelectionLists = false;
    if (options.content && typeof options.content === "object") {
      const contentStr = JSON.stringify(options.content);
      hasSelectionLists = contentStr.includes("selectionList");
      if (hasSelectionLists) {
        window.elixirDebug.info(
          "Selection lists detected in initial content, will use special handling"
        );
      }
    }

    // Import necessary extensions
    // Sanitize formatted content to preserve deleted flag and other attrs
    let initialContentObj = options.content;
    if (typeof initialContentObj === "object") {
      initialContentObj = sanitizeFormattedContent(initialContentObj);
    }

    const editor = new Editor({
      element: element,
      extensions: [
        StarterKit.configure({
          heading: {
            levels: [1, 2, 3],
          },
          hardBreak: {
            keepMarks: true, // Keep marks across hardBreaks
            HTMLAttributes: {
              class: "tiptap-hard-break",
            },
          },
        }),
        ColoredEntity,
        SelectionList, // Add the SelectionList extension
        Placeholder.configure({
          placeholder: options.placeholder || "Inhalt hier eingeben...",
        }),
      ],
      content: hasSelectionLists
        ? { type: "doc", content: [{ type: "paragraph" }] }
        : initialContentObj, // use sanitized object
      onUpdate: options.onUpdate || (() => {}),
      editable: options.editable !== false,
      autofocus: options.autofocus === true,
      injectCSS: false,
      editorProps: {
        preserveWhitespace: "full",
        handleDOMEvents: {
          keydown: (view, event) => {
            // Helper function to trigger content update/save
            const triggerContentSave = () => {
              if (options.onUpdate) {
                setTimeout(() => {
                  if (editor) {
                    options.onUpdate({ editor });
                    window.elixirDebug?.info(
                      "Key event detected, triggering content save"
                    );
                  }
                }, 50);
              }
            };

            // Handle Enter key for hardBreak insertion
            if (event.key === "Enter" && !event.shiftKey) {
              const { state, dispatch } = view;
              const { selection } = state;

              // Insert a hardBreak node at the current selection
              const tr = state.tr.replaceSelectionWith(
                state.schema.nodes.hardBreak.create()
              );

              dispatch(tr);
              return true; // Prevent default Enter behavior
            }

            // Trigger content save on Space, Backspace, Delete
            if (
              event.key === " " ||
              event.key === "Backspace" ||
              event.key === "Delete"
            ) {
              triggerContentSave();
            }

            // Also check for Cut operation (Ctrl+X)
            if (event.key === "x" && (event.ctrlKey || event.metaKey)) {
              triggerContentSave();
            }

            return false;
          },
          paste: (view, event) => {
            // Trigger the update callback explicitly after paste
            if (options.onUpdate) {
              // Use setTimeout to ensure content is updated before we trigger save
              setTimeout(() => {
                if (editor) {
                  options.onUpdate({ editor });
                  window.elixirDebug?.info(
                    "Paste event detected, triggering content save"
                  );
                }
              }, 50);
            }
            // Return false to allow default paste behavior
            return false;
          },
        },
      },
    });

    // Add debug function to editor for convenience
    editor.verifyHardBreaks = () => {
      const json = editor.getJSON();
      return verifyHardBreakPreservation(json);
    };

    // CRITICAL FIX: If we have selection lists, force a proper content refresh after editor creation
    if (
      hasSelectionLists &&
      options.content &&
      typeof options.content === "object"
    ) {
      window.elixirDebug.info(
        "Using special handling for selection lists in initial content"
      );

      // Use a short delay to ensure editor is ready
      setTimeout(() => {
        // First clear any existing content
        editor.commands.clearContent();

        // First insertion
        window.elixirDebug.info("First content insertion for selection lists");
        editor.commands.setContent(options.content);

        // Second insertion with delay to ensure proper rendering
        setTimeout(() => {
          window.elixirDebug.info(
            "Second content insertion for selection lists"
          );
          const currentContent = editor.getJSON();
          editor.commands.clearContent();
          editor.commands.setContent(currentContent);

          // Final check to ensure selection lists rendered
          setTimeout(() => {
            window.elixirDebug.info(
              "Final rendering check for selection lists"
            );
            ensureSelectionListsRendered(editor);

            // Dispatch event to notify hooks that editor is initialized with selection lists
            const event = new CustomEvent("tiptap-editor-initialized", {
              detail: { hasSelectionLists: true },
            });
            element.dispatchEvent(event);
          }, 300);
        }, 400);
      }, 100);
    }

    return editor;
  } catch (e) {
    window.elixirDebug.error("Error initializing editor:", e.message);
    console.error("Error initializing editor:", e);
    return null;
  }
}

// TipTap Editor Hook
const TipTapEditor = {
  mounted() {
    this.contentUpdatePending = false;

    // Add a map to track entity replacements
    this.entityReplacementsCache = {};
    // Add queue for selection entity updates
    this.selectionEntityUpdateQueue = [];

    // Try to recover any pending queue from localStorage
    try {
      const storedQueue = localStorage.getItem(
        `tiptap-selection-queue-${this.el.id}`
      );
      if (storedQueue) {
        this.selectionEntityUpdateQueue = JSON.parse(storedQueue);
        window.elixirDebug?.info(
          `Recovered ${this.selectionEntityUpdateQueue.length} queued updates from localStorage on mount`
        );
      }
    } catch (e) {
      console.error("Failed to recover selection queue from localStorage:", e);
    }

    setTimeout(() => this.initEditor(), 100);

    this.handleEvent("update_editor_content", (payload) => {
      if (this.editor) {
        this.updateEditorContent(payload.content, payload.formatted_content);
      } else {
        this.pendingContent = payload.content;
        this.pendingFormattedContent = payload.formatted_content;
      }
    });

    // Add a handler for queued selection entity updates
    this.handleEvent("queue_selection_entity_updates", (payload) => {
      if (payload.entities && Array.isArray(payload.entities)) {
        window.elixirDebug?.info(
          `Received ${payload.entities.length} selection entity updates to queue`
        );

        // Add these to our queue
        this.selectionEntityUpdateQueue = [
          ...this.selectionEntityUpdateQueue,
          ...payload.entities,
        ];

        // Store the queue in local storage as a backup
        try {
          localStorage.setItem(
            `tiptap-selection-queue-${this.el.id}`,
            JSON.stringify(this.selectionEntityUpdateQueue)
          );
          window.elixirDebug?.info("Backed up selection queue to localStorage");
        } catch (e) {
          console.error("Failed to store selection queue in localStorage:", e);
        }

        // Use a small delay to ensure content update completes first
        setTimeout(() => {
          // If we're not in the middle of an entity update, process the queue
          if (!this.entityUpdatePending) {
            window.elixirDebug?.info(
              "Processing selection queue after short delay"
            );
            this.processSelectionEntityUpdateQueue();
          } else {
            window.elixirDebug?.info(
              "Entity update in progress, queueing selection updates for later"
            );
          }
        }, 200); // Small delay to let other operations complete
      }
    });

    this.handleEvent("force_refresh_editor", (payload) => {
      if (this.editor) {
        this.forceRefreshEditor(payload.content, payload.formatted_content);
      } else {
        this.pendingContent = payload.content;
        this.pendingFormattedContent = payload.formatted_content;
        this.initEditor();
      }
    });

    this.handleEvent("set_editor_mode", (payload) => {
      if (this.editor) {
        this.editor.setEditable(!payload.read_only);
      }
    });
  },

  // Add a method to process the selection entity update queue
  processSelectionEntityUpdateQueue() {
    if (this.selectionEntityUpdateQueue.length === 0) {
      // Try to recover from localStorage if queue is empty
      try {
        const storedQueue = localStorage.getItem(
          `tiptap-selection-queue-${this.el.id}`
        );
        if (storedQueue) {
          this.selectionEntityUpdateQueue = JSON.parse(storedQueue);
          window.elixirDebug?.info(
            `Recovered ${this.selectionEntityUpdateQueue.length} queued updates from localStorage`
          );
        }
      } catch (e) {
        console.error(
          "Failed to recover selection queue from localStorage:",
          e
        );
      }

      // If still empty after recovery attempt, exit
      if (this.selectionEntityUpdateQueue.length === 0) return;
    }

    window.elixirDebug?.info(
      `Processing ${this.selectionEntityUpdateQueue.length} queued selection entity updates`
    );

    // Get the next update
    const update = this.selectionEntityUpdateQueue.shift();

    // Save the updated queue to localStorage
    try {
      localStorage.setItem(
        `tiptap-selection-queue-${this.el.id}`,
        JSON.stringify(this.selectionEntityUpdateQueue)
      );
    } catch (e) {
      console.error("Failed to update selection queue in localStorage:", e);
    }

    // Set a local flag to prevent other operations during this update
    const processingUpdate = true;

    // Send the update to the server
    this.pushEvent(
      "selection-entity-update",
      {
        entity_id: update.entity_id,
        deleted: update.deleted,
        confirmed: update.confirmed,
      },
      (reply) => {
        // After this update is processed, check if there are more in the queue
        window.setTimeout(() => {
          if (this.selectionEntityUpdateQueue.length > 0) {
            window.elixirDebug?.info(
              "Processing next queued selection entity update"
            );
            this.processSelectionEntityUpdateQueue();
          } else {
            // Clear localStorage when queue is empty
            try {
              localStorage.removeItem(`tiptap-selection-queue-${this.el.id}`);
            } catch (e) {
              console.error(
                "Failed to clear selection queue in localStorage:",
                e
              );
            }
          }
        }, 100); // Small delay between updates
      }
    );
  },

  updated() {
    const contentAttr = this.el.getAttribute("data-content");
    const formattedContentAttr = this.el.getAttribute("data-formatted-content");
    const readOnlyAttr = this.el.getAttribute("data-read-only") === "true";

    if (!this.editor) {
      this.initEditor();
      return;
    }

    if (this.readOnly !== readOnlyAttr) {
      this.readOnly = readOnlyAttr;
      this.editor.setEditable(!readOnlyAttr);
    }

    if (this.contentUpdatePending) {
      this.contentUpdatePending = false;
      return;
    }

    const newContent = contentAttr || "";
    const hasNewFormattedContent =
      formattedContentAttr && formattedContentAttr !== "null";

    if (newContent !== this.content || hasNewFormattedContent) {
      this.updateEditorContent(contentAttr, formattedContentAttr);
    }
  },

  destroyed() {
    if (this.entityControlsContainer) {
      this.entityControlsContainer.remove();
    }

    if (this.entityObserver) {
      this.entityObserver.disconnect();
      this.entityObserver = null;
    }

    if (this.editor) {
      this.editor.destroy();
      this.editor = null;
    }
  },

  initEditor() {
    const container = this.el.querySelector(".tiptap-content");
    if (!container) {
      window.elixirDebug.info("Could not find tiptap-content container");
      return;
    }

    const toolbar = this.el.querySelector(".tiptap-toolbar");
    const contentAttr = this.el.getAttribute("data-content") || "";
    const formattedContentAttr = this.el.getAttribute("data-formatted-content");
    const readOnlyAttr = this.el.getAttribute("data-read-only") === "true";

    this.content = contentAttr;
    this.readOnly = readOnlyAttr;

    try {
      // Show loading indicator if it exists
      const loadingOverlay = this.el.querySelector(".tiptap-loading-overlay");
      if (loadingOverlay) {
        loadingOverlay.style.display = "flex";
      }

      // Parse formatted content before editor initialization - if we have it, prioritize it
      let initialContent = contentAttr;
      let hasSelectionLists = false;

      if (formattedContentAttr && formattedContentAttr !== "null") {
        try {
          // Try to parse the formatted content
          const formattedContent = JSON.parse(formattedContentAttr);

          // Check for selection lists in the content for special handling
          hasSelectionLists = checkForSelectionLists(formattedContent);

          if (hasSelectionLists && window.elixirDebug) {
            window.elixirDebug.info(
              "Content contains selection lists, extra care with initialization"
            );
          }

          // Verify it looks like proper TipTap structure before using it
          if (
            formattedContent &&
            formattedContent.type === "doc" &&
            Array.isArray(formattedContent.content)
          ) {
            window.elixirDebug.info(
              "Using formatted content for editor initialization"
            );
            initialContent = formattedContent; // Use formatted content object directly
          }
        } catch (e) {
          window.elixirDebug.info(
            "Error parsing initial formatted content:",
            e
          );
        }
      }

      // Create the editor with the best available content
      this.editor = createBasicTipTapEditor(container, {
        content: initialContent, // This could be either plain text or formatted object
        editable: !readOnlyAttr,
        placeholder: "Inhalt hier eingeben...",
        onUpdate: ({ editor }) => {
          if (this.preventNextUpdate) {
            this.preventNextUpdate = false;
            return;
          }

          clearTimeout(this.saveTimeout);
          this.saveTimeout = setTimeout(() => {
            const json = editor.getJSON();
            const text = editor.getText();

            this.contentUpdatePending = true;
            this.lastSavedContent = text;
            this.lastFormattedContent = JSON.stringify(json);

            // Ensure we're including formatted_content in the event data
            // Add a flag to force persistence on all content updates
            this.pushEvent("content-updated", {
              content: text,
              formatted_content: JSON.stringify(json),
              persist_entities: true, // Always persist on content changes
            });

            // Debug log to trace update flow
            window.elixirDebug.info(
              "Content update triggered - sending to server:",
              text.substring(0, 20) + "..."
            );
          }, 300); // Time to wait before sending the update
        },
      });

      // Apply deletion styling immediately after editor creation
      setTimeout(() => {
        this.applyDeletionStyling();
        console.log(
          "Applied deletion styling immediately after editor creation"
        );
      }, 10);

      this.setupEntityObserver();

      // Special handling for content with selection lists
      if (hasSelectionLists) {
        // Additional initialization steps for selection lists
        setTimeout(() => {
          ensureSelectionListsRendered(this.editor);
        }, 200);
      }

      // Only handle pendingFormattedContent if we didn't use formatted content initially
      if (this.pendingFormattedContent && typeof initialContent === "string") {
        setTimeout(() => {
          this.updateEditorContent(
            this.pendingContent,
            this.pendingFormattedContent
          );
          this.pendingContent = null;
          this.pendingFormattedContent = null;
        }, 100);
      }

      if (toolbar) createSimpleToolbar(toolbar, this.editor, this.readOnly);

      // Ensure deleted entities are properly styled on initial load
      this.applyDeletionStylingWithRetry(5);

      // Register an 'initialized' event
      const event = new CustomEvent("tiptap-editor-initialized", {
        bubbles: true,
        detail: { hasSelectionLists },
      });
      this.el.dispatchEvent(event);
    } catch (e) {
      window.elixirDebug.info("Error initializing editor:", e);

      // Hide loading overlay in case of error
      const loadingOverlay = this.el.querySelector(".tiptap-loading-overlay");
      if (loadingOverlay) {
        loadingOverlay.classList.add("hidden");
      }
    }
  },

  setupEntityBoundaries() {
    this.editor.view.dom.addEventListener("keypress", (event) => {
      const { $from, $to } = this.editor.state.selection;

      const isAtEntityBoundary =
        $from.marks().some((mark) => mark.type.name === "coloredEntity") ||
        $to.marks().some((mark) => mark.type.name === "coloredEntity");

      // Log to Elixir if we have the debug utility available
      if (window.elixirDebug) {
        window.elixirDebug.debug(
          `Entity boundary check: ${isAtEntityBoundary}`,
          {
            from: $from.pos,
            to: $to.pos,
            key: event.key,
          }
        );
      }

      if (isAtEntityBoundary) {
        // Force mark boundary reset after next transaction
        setTimeout(() => {
          this.preventNextUpdate = true;
          this.editor.commands.unsetMark("coloredEntity");
          this.editor.commands.setMeta("preventMarkContinuation", true);
        }, 0);
      }
    });
  },

  updateEditorContent(content, formattedContent) {
    if (!this.editor) return;

    try {
      // Prevent feedback loop
      this.preventNextUpdate = true;

      if (formattedContent && formattedContent !== "null") {
        // Log using the debug utility if available
        if (window.elixirDebug) {
          window.elixirDebug.info("Updating editor with formatted content", {
            contentLength: content?.length || 0,
            hasFormattedContent: !!formattedContent,
          });
        }
      } else {
        // Log using the debug utility if available
        if (window.elixirDebug) {
          window.elixirDebug.info("Updating editor with plain content", {
            contentLength: content?.length || 0,
          });
        }
      }
    } catch (e) {
      // Log errors to Elixir
      if (window.elixirDebug) {
        window.elixirDebug.error(
          `Error updating editor content: ${e.message}`,
          {
            stack: e.stack,
            contentLength: content?.length || 0,
            hasFormattedContent: !!formattedContent,
          }
        );
      }
    }
  },

  // Add or modify the forceRefreshEditor method in TipTapEditor object

  forceRefreshEditor(content, formattedContentStr) {
    try {
      // Log the operation
      window.elixirDebug.info(
        `Forcing editor refresh with content length: ${content?.length || 0}`
      );

      // Parse the formatted content if it's a string
      let formattedContent = null;
      if (formattedContentStr && typeof formattedContentStr === "string") {
        try {
          formattedContent = JSON.parse(formattedContentStr);
          window.elixirDebug.info(
            `Parsed formatted content with ${
              formattedContent.content?.length || 0
            } blocks`
          );
        } catch (e) {
          window.elixirDebug.error(
            `Error parsing formatted content: ${e.message}`
          );
          // If we couldn't parse it, but it's already an object, use it directly
          if (typeof formattedContentStr === "object") {
            formattedContent = formattedContentStr;
          }
        }
      } else if (typeof formattedContentStr === "object") {
        formattedContent = formattedContentStr;
      }

      // Ensure we have a valid editor
      if (!this.editor) {
        window.elixirDebug.error(
          "Cannot refresh editor - editor not initialized"
        );
        this.initEditor();

        if (!this.editor) {
          window.elixirDebug.error(
            "Failed to initialize editor during refresh"
          );
          return;
        }
      }

      // Clear the editor's content first
      this.editor.commands.clearContent();

      // Verify if formatted content has selection lists
      const hasSelectionLists =
        JSON.stringify(formattedContent).includes("selectionList");

      if (hasSelectionLists) {
        window.elixirDebug.info(
          "Content contains selection lists, using special handling"
        );

        // Special handling for selection lists
        // First insert just the basic content
        this.editor.commands.setContent(formattedContent);

        // Then with a delay, re-insert to ensure proper rendering
        setTimeout(() => {
          // Force a state update to ensure selection lists render
          const currentState = this.editor.getJSON();
          this.editor.commands.clearContent();
          this.editor.commands.setContent(currentState);

          window.elixirDebug.info(
            "Selection lists should now be properly rendered"
          );
        }, 300);
      } else {
        // Standard content insertion
        this.editor.commands.setContent(formattedContent);
      }

      // Apply deletion styling immediately after content is loaded
      setTimeout(() => {
        this.applyDeletionStyling();
        console.log("Applied deletion styling after force refresh");
      }, 50);

      // Also apply after a longer delay to catch any elements that render later
      setTimeout(() => {
        this.applyDeletionStyling();
        console.log("Applied deletion styling after longer delay");
      }, 500);
    } catch (err) {
      window.elixirDebug.error(`Error in forceRefreshEditor: ${err.message}`);
      console.error("Error in forceRefreshEditor:", err);
    }
  },

  entityUpdatePending: false,
  pendingSelectionUpdate: null,

  saveContentWithEntityChanges() {
    clearTimeout(this.saveTimeout);

    // Set a flag indicating an entity update is in progress
    this.entityUpdatePending = true;

    this.saveTimeout = setTimeout(() => {
      // Get the editor's content
      const json = this.editor.getJSON();
      const text = this.editor.getText();

      // CRITICAL FIX: Preserve deleted entities that might be lost during serialization
      // by ensuring they remain in the JSON structure
      const preservedJson = this.preserveDeletedEntities(json);

      this.contentUpdatePending = true;
      this.lastSavedContent = text;
      this.lastFormattedContent = JSON.stringify(preservedJson);

      // Send the content update to the server with the preserved JSON
      this.pushEvent(
        "content-updated",
        {
          content: text,
          formatted_content: JSON.stringify(preservedJson),
          persist_entities: true,
        },
        (reply) => {
          // When we get a reply, clear the pending flag
          this.entityUpdatePending = false;

          // Check if we have any queued selection entity updates
          if (this.selectionEntityUpdateQueue.length > 0) {
            window.elixirDebug?.info(
              `Processing ${this.selectionEntityUpdateQueue.length} queued selection entity updates after entity update`
            );
            this.processSelectionEntityUpdateQueue();
          }

          // Also process any pending selection update
          if (this.pendingSelectionUpdate) {
            const { entityId, deleted, confirmed } =
              this.pendingSelectionUpdate;
            this.pendingSelectionUpdate = null;
            this.pushEvent("selection-entity-update", {
              entity_id: entityId,
              deleted: deleted,
              confirmed: confirmed,
            });
          }
        }
      );
    }, 50);
  },

  // Add this new helper function to preserve deleted entities
  preserveDeletedEntities(json) {
    // Maintain a record of deleted entities we've found
    const deletedEntities = [];

    // First, scan for any existing deleted entities and store them
    const scanForDeletedEntities = (node) => {
      if (!node || typeof node !== "object") return;

      // Check for deleted entity marks
      if (node.marks && Array.isArray(node.marks)) {
        const entityMark = node.marks.find(
          (m) =>
            m.type === "coloredEntity" && m.attrs && m.attrs.deleted === true
        );

        if (entityMark) {
          // Store this deleted entity so we can ensure it's preserved
          deletedEntities.push({
            entityId: entityMark.attrs.entityId,
            text: node.text,
            mark: entityMark,
          });
          window.elixirDebug?.info(
            `Found deleted entity to preserve: ${entityMark.attrs.entityId}`
          );
        }
      }

      // Recurse through content arrays
      if (node.content && Array.isArray(node.content)) {
        node.content.forEach(scanForDeletedEntities);
      }
    };

    // Scan the document for deleted entities
    scanForDeletedEntities(json);

    // If we found deleted entities that need preservation, ensure they exist in the final JSON
    if (deletedEntities.length > 0) {
      window.elixirDebug?.info(
        `Found ${deletedEntities.length} deleted entities to preserve`
      );

      // Make a deep copy to avoid mutating the original JSON
      const result = JSON.parse(JSON.stringify(json));

      // Check if our deleted entities still exist in the result
      const checkAndEnsureDeletedEntities = () => {
        deletedEntities.forEach((entity) => {
          let found = false;

          // Function to search through the document for the entity
          const searchForEntity = (node) => {
            if (!node || typeof node !== "object") return false;

            // Check if this node has the entity mark
            if (node.marks && Array.isArray(node.marks)) {
              const hasEntity = node.marks.some(
                (m) =>
                  m.type === "coloredEntity" &&
                  m.attrs &&
                  m.attrs.entityId === entity.entityId
              );

              if (hasEntity) {
                found = true;
                return true;
              }
            }

            // Check children
            if (node.content && Array.isArray(node.content)) {
              return node.content.some(searchForEntity);
            }

            return false;
          };

          // Search the document for this entity
          searchForEntity(result);

          // If the entity wasn't found, we need to add it back
          if (!found) {
            window.elixirDebug?.info(
              `Preserving deleted entity that was lost: ${entity.entityId}`
            );

            // Add it to the first paragraph
            if (
              result.content &&
              result.content.length > 0 &&
              result.content[0].type === "paragraph" &&
              result.content[0].content
            ) {
              // Create a node with the deleted entity mark
              const preservedNode = {
                type: "text",
                text: entity.text,
                marks: [entity.mark],
              };

              // Add it near the end of the first paragraph
              result.content[0].content.push(preservedNode);
            }
          }
        });
      };

      // Run the check and preservation
      checkAndEnsureDeletedEntities();
      return result;
    }

    // No deleted entities to preserve, return original
    return json;
  },

  // Import entity handling methods from the other files
  ...require("./tip_tap_entities.js").EntityHandlingMethods,

  // Ensure deletion styling is accessible from the editor object
  applyDeletionStyling() {
    if (!this.editor || !this.editor.view || !this.editor.view.dom) return;

    console.log("Applying deletion styling to entities from document state");

    // First approach: Check the DOM elements
    const entityElements =
      this.editor.view.dom.querySelectorAll(".colored-entity");

    // Apply styling based on data-deleted attribute and mark class
    entityElements.forEach((el) => {
      const isDeleted = el.getAttribute("data-deleted") === "true";
      if (isDeleted) {
        el.classList.add("marked-for-deletion");
        el.style.backgroundColor = "#ffcccc";
        el.style.textDecoration = "line-through";
        el.style.color = "#999";
        el.style.border = "1px dashed #ff5555";
      } else {
        el.classList.remove("marked-for-deletion");
      }
    });

    // Second approach: Check the editor's JSON content directly
    try {
      const jsonContent = this.editor.getJSON();
      if (jsonContent && jsonContent.content) {
        // Find deleted entities in the JSON content
        const deletedEntityIds = this.findDeletedEntitiesInContent(jsonContent);

        if (deletedEntityIds.length > 0) {
          console.log(
            "Found deleted entities in JSON content:",
            deletedEntityIds
          );

          // Apply styling to these entities in the DOM
          deletedEntityIds.forEach((entityId) => {
            const entityElements = this.editor.view.dom.querySelectorAll(
              `.colored-entity[data-entity-id="${entityId}"]`
            );

            entityElements.forEach((el) => {
              el.classList.add("marked-for-deletion");
              el.setAttribute("data-deleted", "true");
              el.style.backgroundColor = "#ffcccc";
              el.style.textDecoration = "line-through";
              el.style.color = "#999";
              el.style.border = "1px dashed #ff5555";
            });
          });
        }
      }
    } catch (error) {
      console.error(
        "Error while checking JSON content for deleted entities:",
        error
      );
    }

    // Third approach: Check the document state in ProseMirror
    try {
      const deletedEntities = this.findDeletedEntitiesInState();
      deletedEntities.forEach((entityId) => {
        const entityElements = this.editor.view.dom.querySelectorAll(
          `.colored-entity[data-entity-id="${entityId}"]`
        );

        entityElements.forEach((el) => {
          el.classList.add("marked-for-deletion");
          el.setAttribute("data-deleted", "true");
          el.style.backgroundColor = "#ffcccc";
          el.style.textDecoration = "line-through";
          el.style.color = "#999";
          el.style.border = "1px dashed #ff5555";
        });
      });
    } catch (error) {
      console.error(
        "Error while checking document state for deleted entities:",
        error
      );
    }
  },

  // Add a new function to scan content recursively for deleted entities
  findDeletedEntitiesInContent(content) {
    const deletedIds = [];

    const scanNode = (node) => {
      if (!node) return;

      // Check if this is a text node with marks
      if (node.text && node.marks && Array.isArray(node.marks)) {
        // Find any coloredEntity marks that are deleted
        node.marks.forEach((mark) => {
          if (
            mark.type === "coloredEntity" &&
            mark.attrs &&
            (mark.attrs.deleted === true ||
              mark.attrs["data-deleted"] === "true")
          ) {
            if (
              mark.attrs.entityId &&
              !deletedIds.includes(mark.attrs.entityId)
            ) {
              deletedIds.push(mark.attrs.entityId);
              console.log(
                `Found deleted entity in content: ${mark.attrs.entityId}`
              );
            }
          }
        });
      }

      // Recursively check content arrays
      if (node.content && Array.isArray(node.content)) {
        node.content.forEach(scanNode);
      }
    };

    // Start scanning from the root
    scanNode(content);
    return deletedIds;
  },
};

// Helper function to check if content contains selection lists
function checkForSelectionLists(content) {
  if (!content || typeof content !== "object") return false;

  // Check for direct selectionList nodes
  if (content.content && Array.isArray(content.content)) {
    const hasDirectSelectionList = content.content.some(
      (node) => node.type === "selectionList"
    );

    if (hasDirectSelectionList) return true;

    // Check for lists with selection_list mark
    const hasListWithSelectionMark = content.content.some(
      (node) =>
        node.type === "list" &&
        node.marks &&
        node.marks.some(
          (mark) =>
            mark.type === "coloredEntity" &&
            mark.attrs &&
            mark.attrs.entityType === "selection_list"
        )
    );

    if (hasListWithSelectionMark) return true;

    // Recursively check child content
    return content.content.some(
      (node) =>
        node.content &&
        Array.isArray(node.content) &&
        checkForSelectionLists(node)
    );
  }

  return false;
}

// Helper function to ensure selection lists are properly rendered
function ensureSelectionListsRendered(editor) {
  if (!editor) return;

  // Get the DOM nodes for any selection lists
  const editorElement = editor.view.dom;
  const selectionLists = editorElement.querySelectorAll(
    ".selection-list-container"
  );

  if (selectionLists.length > 0) {
    window.elixirDebug.info(
      `Found ${selectionLists.length} selection lists, ensuring they're expanded`
    );

    // Make sure they're expanded and visible
    selectionLists.forEach((list) => {
      if (!list.classList.contains("expanded")) {
        list.classList.add("expanded");
      }

      // Make sure the table is visible
      const table = list.querySelector(".selection-list-table");
      if (table) {
        table.style.display = "table";
      }
    });

    // Force a re-render to make sure everything is properly displayed
    setTimeout(() => {
      const tr = editor.state.tr;
      editor.view.dispatch(tr.setMeta("forceUpdate", true));
    }, 100);
  }
}

// Update the global event listener for selection list events
document.addEventListener("haimeda:selection-entity-update", function (event) {
  console.log(
    "Document received selection-entity-update global event:",
    event.detail
  );

  // Find a hook element we can use to push the event
  const editorHooks = document.querySelectorAll("[phx-hook]");
  let hookFound = false;

  // Try to find a hook to push the event through
  for (const hookElement of editorHooks) {
    if (
      hookElement._phxHook &&
      typeof hookElement._phxHook.pushEvent === "function" &&
      hookElement.id.includes("tiptap-editor")
    ) {
      console.log(
        "Using editor hook to push selection-entity-update event:",
        hookElement.id
      );

      // Check if there's a pending entity update
      if (hookElement._phxHook.entityUpdatePending) {
        console.log("Entity update pending, queueing selection update");

        // Add to the queue instead of setting pendingSelectionUpdate
        if (!hookElement._phxHook.selectionEntityUpdateQueue) {
          hookElement._phxHook.selectionEntityUpdateQueue = [];
        }

        hookElement._phxHook.selectionEntityUpdateQueue.push({
          entity_id: event.detail.entity_id,
          deleted: event.detail.deleted,
          confirmed: event.detail.confirmed,
        });
      } else {
        // No pending update, proceed normally
        hookElement._phxHook.pushEvent("selection-entity-update", {
          entity_id: event.detail.entity_id,
          deleted: event.detail.deleted,
          confirmed: event.detail.confirmed,
        });
      }

      hookFound = true;
      break;
    }
  }

  if (!hookFound) {
    console.warn(
      "Could not find a hook to forward selection-entity-update event"
    );
  }
});

export default TipTapEditor;
