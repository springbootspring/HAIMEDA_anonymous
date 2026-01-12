import { Editor } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";
import Placeholder from "@tiptap/extension-placeholder";
import { Mark } from "@tiptap/core";

// Improved mark for colored entities
const ColoredEntity = Mark.create({
  name: "coloredEntity",

  addOptions() {
    return {
      HTMLAttributes: {
        class: "colored-entity",
      },
    };
  },

  // Control mark inclusivity
  inclusive: false, // This makes the mark non-inclusive, so typing at the boundary won't extend the mark

  // Ensure this mark is contained within its current boundaries
  excludes: "_", // Exclude all other marks from continuing, including itself

  addAttributes() {
    return {
      entityId: {
        default: null,
      },
      entityType: {
        default: null,
      },
      entityColor: {
        default: "#d8b5ff",
      },
      entityCategory: {
        default: null,
      },
      replacements: {
        default: [],
        parseHTML: (element) => {
          const replacements = element.getAttribute("data-replacements");
          try {
            if (
              replacements &&
              replacements.startsWith("[") &&
              replacements.endsWith("]")
            ) {
              return JSON.parse(replacements);
            }
            return replacements ? replacements.split(",") : [];
          } catch (e) {
            console.error("Error parsing replacements:", e);
            return [];
          }
        },
        renderHTML: (attributes) => {
          if (!attributes.replacements || !attributes.replacements.length)
            return {};

          return {
            "data-replacements": JSON.stringify(attributes.replacements),
          };
        },
      },
      originalText: {
        default: "",
      },
      currentText: {
        default: "",
      },
      displayText: {
        default: "",
      },
      deleted: {
        default: false,
        parseHTML: (element) => {
          return element.getAttribute("data-deleted") === "true";
        },
        renderHTML: (attributes) => {
          if (!attributes.deleted) return {};
          return { "data-deleted": "true" };
        },
      },
    };
  },

  parseHTML() {
    return [
      {
        tag: "span.colored-entity",
      },
    ];
  },

  renderHTML({ HTMLAttributes }) {
    const cleanedAttrs = { ...HTMLAttributes };

    let entityClass = "colored-entity";
    if (HTMLAttributes.deleted) {
      entityClass += " marked-for-deletion";
    }

    return [
      "span",
      {
        ...this.options.HTMLAttributes,
        ...cleanedAttrs,
        style: `background-color: ${HTMLAttributes.entityColor || "#d8b5ff"};${
          HTMLAttributes.deleted ? " text-decoration: line-through;" : ""
        }`,
        class: entityClass,
        "data-entity-id": HTMLAttributes.entityId || `entity-${Date.now()}`,
        "data-entity-type": HTMLAttributes.entityType || "unknown",
        "data-deleted": HTMLAttributes.deleted ? "true" : "false",
      },
      0,
    ];
  },
});

// TipTap Editor Hook
const TipTapEditor = {
  mounted() {
    this.tabId = this.el.getAttribute("data-tab-id");

    this.lastSavedContent = "";
    this.lastFormattedContent = "";
    this.preventNextUpdate = false;
    this.contentUpdatePending = false;

    setTimeout(() => this.initEditor(), 100);

    this.handleEvent("update_editor_content", (payload) => {
      if (this.editor) {
        this.updateEditorContent(payload.content, payload.formatted_content);
      } else {
        this.pendingContent = payload.content;
        this.pendingFormattedContent = payload.formatted_content;
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
      console.error("Could not find tiptap-content container");
      return;
    }

    const toolbar = this.el.querySelector(".tiptap-toolbar");
    const contentAttr = this.el.getAttribute("data-content") || "";
    const formattedContentAttr = this.el.getAttribute("data-formatted-content");
    const readOnlyAttr = this.el.getAttribute("data-read-only") === "true";

    this.content = contentAttr;
    this.readOnly = readOnlyAttr;

    try {
      this.editor = new Editor({
        element: container,
        extensions: [
          StarterKit,
          Placeholder.configure({
            placeholder: "Inhalt hier eingeben...",
          }),
          ColoredEntity,
        ],
        content: contentAttr,
        editable: !readOnlyAttr,
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

            this.pushEvent("content-updated", {
              content: text,
              formatted_content: JSON.stringify(json),
            });
          }, 500);
        },
        onTransaction: ({ transaction }) => {
          // Apply deletion styling after each transaction
          setTimeout(() => this.applyDeletionStyling(), 10);

          // Check if we need to handle entity boundaries
          if (transaction.getMeta("preventMarkContinuation")) {
            console.log("Preventing mark continuation at entity boundary");
            this.preventNextUpdate = true;
          }
        },
        onCreate: ({ editor }) => {
          console.log("TipTap editor created");
          // Apply styling with multiple retry attempts
          this.applyDeletionStylingWithRetry(5);

          // Setup entity boundary handling
          this.setupEntityBoundaries();
        },
      });

      this.setupEntityObserver();

      if (this.pendingFormattedContent) {
        setTimeout(() => {
          this.updateEditorContent(
            this.pendingContent,
            this.pendingFormattedContent
          );
          this.pendingContent = null;
          this.pendingFormattedContent = null;
        }, 100);
      } else if (formattedContentAttr && formattedContentAttr !== "null") {
        try {
          const formattedContent = JSON.parse(formattedContentAttr);
          setTimeout(() => {
            this.preventNextUpdate = true;
            this.editor.commands.setContent(formattedContent);
          }, 100);
        } catch (e) {
          console.error("Error parsing formatted content:", e);
          this.editor.commands.setContent(contentAttr || "");
        }
      }

      if (toolbar) this.createSimpleToolbar(toolbar);

      // Ensure deleted entities are properly styled on initial load
      this.applyDeletionStylingWithRetry(5);
    } catch (e) {
      console.error("Error initializing editor:", e);
    }
  },

  setupEntityBoundaries() {
    if (!this.editor) return;

    // Listen for keypress events on the editor - NOT click events
    this.editor.view.dom.addEventListener("keypress", (event) => {
      const { state, view } = this.editor;
      const { selection } = state;
      const { $from, $to } = selection;

      // Check if we're at the boundary of an entity mark
      const isAtEntityBoundary =
        $from.marks().some((mark) => mark.type.name === "coloredEntity") ||
        $to.marks().some((mark) => mark.type.name === "coloredEntity");

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

  setupEntityObserver() {
    this.entityOverlay = document.createElement("div");
    this.entityOverlay.className = "entity-controls-overlay";
    document.body.appendChild(this.entityOverlay);

    // Improved click event handling for entity elements
    this.editor.view.dom.addEventListener("click", (e) => {
      const entity = e.target.closest(".colored-entity");
      if (entity) {
        e.preventDefault(); // Prevent default to ensure the click is captured
        e.stopPropagation(); // Stop propagation to prevent any parent handlers
        this.showEntityOverlay(entity);
      }
    });

    // Improved global click handler to close the overlay when clicking outside
    // This handler should be triggered for ALL clicks outside the dropdown
    document.addEventListener("mousedown", (e) => {
      // Check if click is outside both the entity and the dropdown
      if (
        this.entityOverlay &&
        this.entityOverlay.style.display !== "none" &&
        !this.entityOverlay.contains(e.target) &&
        !e.target.closest(".colored-entity")
      ) {
        this.hideEntityOverlay();
      }
    });

    // Add an escape key handler to close the overlay
    document.addEventListener("keydown", (e) => {
      if (
        e.key === "Escape" &&
        this.entityOverlay &&
        this.entityOverlay.style.display !== "none"
      ) {
        this.hideEntityOverlay();
      }
    });

    this.activeEntityElement = null;

    // Improved scroll handling - listen to all possible scroll containers
    // Main window scroll
    window.addEventListener(
      "scroll",
      () => {
        if (
          this.activeEntityElement &&
          this.entityOverlay.style.display !== "none"
        ) {
          this.updateEntityOverlayPosition();
        }
      },
      { passive: true, capture: true } // Use capture to ensure we get all scroll events
    );

    // Also track scrolling in any parent scrollable containers
    document.addEventListener(
      "scroll",
      (e) => {
        if (
          this.activeEntityElement &&
          this.entityOverlay.style.display !== "none"
        ) {
          this.updateEntityOverlayPosition();
        }
      },
      { passive: true, capture: true } // Use capture to ensure we get all scroll events
    );

    // Also listen for window resize which would affect positioning
    window.addEventListener("resize", () => {
      if (
        this.activeEntityElement &&
        this.entityOverlay.style.display !== "none"
      ) {
        this.updateEntityOverlayPosition();
      }
    });

    this.editor.on("update", () => {
      this.makeEntitiesClickable();
    });
  },

  updateEntityOverlayPosition() {
    if (!this.activeEntityElement || !this.entityOverlay) return;

    // Get updated position of the entity element, taking scrolling into account
    const rect = this.activeEntityElement.getBoundingClientRect();

    // Position is relative to the viewport, already accounting for scroll
    const top = rect.bottom + 5; // 5px below the element

    // Ensure the overlay stays within the viewport
    const viewportHeight = window.innerHeight;
    const overlayHeight = this.entityOverlay.offsetHeight || 200;

    // Check if overlay would go below viewport
    const finalTop =
      top + overlayHeight > viewportHeight
        ? rect.top - overlayHeight - 5 // Position above if it would overflow bottom
        : top; // Otherwise position below

    // Center horizontally beneath the entity
    const overlayWidth = this.entityOverlay.offsetWidth || 200;
    const idealLeft = rect.left + rect.width / 2 - overlayWidth / 2;

    // Don't let it go off-screen horizontally
    const viewportWidth = window.innerWidth;
    const finalLeft = Math.max(
      10,
      Math.min(idealLeft, viewportWidth - overlayWidth - 10)
    );

    // Apply the calculated position
    this.entityOverlay.style.top = `${finalTop}px`;
    this.entityOverlay.style.left = `${finalLeft}px`;

    // Ensure visibility
    this.entityOverlay.style.zIndex = "1000";
    this.entityOverlay.style.visibility = "visible";

    // Log the positioning for debugging
    console.log(
      `Positioned overlay at ${finalTop}px from top, ${finalLeft}px from left`
    );
  },

  showEntityOverlay(entity) {
    if (!this.entityOverlay) return;

    console.log("Attempting to show entity overlay");

    this.activeEntityElement = entity;

    const entityId = entity.getAttribute("data-entity-id");

    // Get the entity text directly from the current DOM element
    const entityText = entity.textContent;

    // Explicitly log the current text to verify what we're working with
    console.log(`Current entity text: "${entityText}"`);

    // Get replacements with improved logging
    let replacements = this.getEntityReplacementsFromState(entityId);
    console.log(`Replacements from state: ${JSON.stringify(replacements)}`);

    if (!replacements || replacements.length === 0) {
      // Fallback to DOM attribute if needed
      const replacementsAttr = entity.getAttribute("data-replacements");
      console.log(`Replacements from DOM attribute: ${replacementsAttr}`);

      try {
        if (replacementsAttr && replacementsAttr.trim()) {
          if (
            replacementsAttr.startsWith("[") &&
            replacementsAttr.endsWith("]")
          ) {
            replacements = JSON.parse(replacementsAttr);
          } else {
            replacements = replacementsAttr.split(",").filter((r) => r.trim());
          }
        }
      } catch (e) {
        console.error("Error parsing replacements:", e);
        replacements = [];
      }
    }

    // Ensure replacements is an array of unique strings and filter out empty strings
    replacements = Array.isArray(replacements) ? replacements : [];

    // Clean the replacements array
    replacements = [
      ...new Set(
        replacements.map((r) => String(r).trim()).filter((r) => r !== "") // Remove empty strings
      ),
    ];

    console.log(`Processed replacements: ${JSON.stringify(replacements)}`);

    const isMarkedForDeletion =
      entity.classList.contains("marked-for-deletion") ||
      entity.getAttribute("data-deleted") === "true";

    this.entityOverlay.innerHTML = "";

    const header = document.createElement("div");
    header.className = "entity-controls-header";

    const deleteBtn = document.createElement("button");
    deleteBtn.className = isMarkedForDeletion
      ? "entity-restore-btn"
      : "entity-delete-btn";
    deleteBtn.textContent = isMarkedForDeletion
      ? "Entität wiederherstellen"
      : "Entität entfernen";
    deleteBtn.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();

      if (isMarkedForDeletion) {
        entity.classList.remove("marked-for-deletion");
        entity.setAttribute("data-deleted", "false");

        entity.style.backgroundColor = "";
        entity.style.textDecoration = "";
        entity.style.color = "";
        entity.style.border = "";

        this.restoreEntityFromDeletion(entityId);
        console.log(`Restoring entity from deletion: ${entityId}`);

        this.pushEvent("entity-restore", { entity_id: entityId });
      } else {
        entity.classList.add("marked-for-deletion");
        this.pushEvent("entity-deletion", { entity_id: entityId });
        this.markEntityForDeletion(entityId);
      }

      this.hideEntityOverlay();
    });

    header.appendChild(deleteBtn);
    this.entityOverlay.appendChild(header);

    const replacementsSection = document.createElement("div");
    replacementsSection.className = "entity-replacements";

    const replacementsTitle = document.createElement("div");
    replacementsTitle.className = "entity-replacements-title";
    replacementsTitle.textContent = "Alternative Entitäten:";
    replacementsSection.appendChild(replacementsTitle);

    // Always add current text at the top as selected item
    const currentTextItem = document.createElement("div");
    currentTextItem.className = "entity-replacement-item entity-current-text";
    currentTextItem.textContent = entityText + " (aktuell)";
    replacementsSection.appendChild(currentTextItem);

    // IMPORTANT: We need to strictly filter out the EXACT entity text
    // Using strict equality to ensure exact matches are filtered
    const filteredReplacements = replacements.filter((r) => r !== entityText);
    console.log(
      `Filtered replacements: ${JSON.stringify(filteredReplacements)}`
    );

    if (filteredReplacements && filteredReplacements.length > 0) {
      // Add alternative replacements
      filteredReplacements.forEach((replacement) => {
        // Skip empty strings or exact matches with current text (redundant check)
        if (!replacement || replacement === entityText) return;

        const item = document.createElement("div");
        item.className = "entity-replacement-item";
        item.textContent = replacement;

        item.addEventListener("click", (e) => {
          e.preventDefault();
          e.stopPropagation();
          this.replaceEntityText(entityId, replacement);
          this.hideEntityOverlay();
        });

        replacementsSection.appendChild(item);
      });
    } else {
      const noReplacements = document.createElement("div");
      noReplacements.className = "entity-no-replacements";
      noReplacements.textContent = "Keine Alternativen verfügbar";
      replacementsSection.appendChild(noReplacements);
    }

    this.entityOverlay.appendChild(replacementsSection);

    const customTextSection = document.createElement("div");
    customTextSection.className = "entity-custom-text";

    const customTextTitle = document.createElement("div");
    customTextTitle.className = "entity-custom-text-title";
    customTextTitle.textContent = "Anderen Text verwenden:";
    customTextSection.appendChild(customTextTitle);

    const customTextInput = document.createElement("input");
    customTextInput.type = "text";
    customTextInput.className = "entity-custom-text-input";
    customTextInput.placeholder = "Eigenen Text eingeben...";
    customTextInput.value = "";

    customTextInput.addEventListener("blur", (e) => {
      const customText = e.target.value.trim();
      if (customText && customText !== entityText) {
        this.replaceEntityWithCustomText(entityId, customText, entityText);
        this.hideEntityOverlay();
      }
    });

    customTextInput.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        const customText = e.target.value.trim();
        if (customText && customText !== entityText) {
          this.replaceEntityWithCustomText(entityId, customText, entityText);
          this.hideEntityOverlay();
        }
      }
    });

    customTextSection.appendChild(customTextInput);
    this.entityOverlay.appendChild(customTextSection);

    const preventPropagation = (e) => {
      e.stopPropagation();
    };

    this.entityOverlay.addEventListener("mousedown", preventPropagation);

    this.updateEntityOverlayPosition();

    this.entityOverlay.style.display = "block";
    this.entityOverlay.style.visibility = "visible";
    this.entityOverlay.style.opacity = "1";

    this.activeEntityId = entityId;

    setTimeout(() => {
      customTextInput.focus();
    }, 100);
  },

  hideEntityOverlay() {
    if (this.entityOverlay) {
      this.entityOverlay.style.display = "none";
      this.entityOverlay.style.visibility = "hidden";
      this.activeEntityElement = null;
      this.activeEntityId = null;
    }
  },

  getEntityReplacementsFromState(entityId) {
    if (!this.editor || !this.editor.state) return [];

    const { doc } = this.editor.state;
    let foundReplacements = null;

    doc.descendants((node, pos) => {
      if (foundReplacements !== null) return false;

      if (node.isText) {
        const mark = node.marks.find(
          (m) =>
            m.type.name === "coloredEntity" && m.attrs.entityId === entityId
        );

        if (mark) {
          // Ensure replacements is an array
          foundReplacements = Array.isArray(mark.attrs.replacements)
            ? mark.attrs.replacements
            : [];

          // Log what we found for debugging
          console.log(
            `Found replacements in state for entity ${entityId}:`,
            foundReplacements
          );
          return false;
        }
      }
      return true;
    });

    return foundReplacements || [];
  },

  replaceEntityText(entityId, replacement) {
    console.log(`Replacing entity ${entityId} with: ${replacement}`);

    const entityElements = this.editor.view.dom.querySelectorAll(
      `.colored-entity[data-entity-id="${entityId}"]`
    );

    if (entityElements.length === 0) {
      console.warn(`Entity with ID ${entityId} not found in DOM`);
      return;
    }

    // Get current entity text before replacing it
    const entityText = entityElements[0].textContent;
    console.log(`Original entity text: "${entityText}"`);

    // Update DOM elements right away
    entityElements.forEach((el) => {
      el.textContent = replacement;
    });

    const selectedColor = "#a8d1ff";

    this.pushEvent("entity-replace", {
      entity_id: entityId,
      replacement: replacement,
      original: entityText,
      display_text: replacement,
      selected_color: selectedColor,
    });

    const { state } = this.editor;
    const { tr } = state;
    let found = false;

    state.doc.descendants((node, pos) => {
      if (found) return false;

      if (
        node.isText &&
        node.marks.some(
          (mark) =>
            mark.type.name === "coloredEntity" &&
            mark.attrs.entityId === entityId
        )
      ) {
        const mark = node.marks.find(
          (m) =>
            m.type.name === "coloredEntity" && m.attrs.entityId === entityId
        );

        // Ensure the replacements array exists and is properly initialized
        let replacements = Array.isArray(mark.attrs.replacements)
          ? [...mark.attrs.replacements]
          : [];

        console.log(
          `Current replacements before update: ${JSON.stringify(replacements)}`
        );

        // IMPORTANT: Add the current text to replacements and remove the replacement
        // We filter out the new text and add the old one
        replacements = replacements
          .filter((r) => r !== replacement && r !== "") // Remove the new replacement and empty strings
          .concat(entityText) // Add the current text to alternatives
          .filter((v, i, a) => a.indexOf(v) === i); // Deduplicate

        console.log(`Updated replacements: ${JSON.stringify(replacements)}`);

        // Create an updated mark with the new replacements
        const updatedMark = mark.type.create({
          ...mark.attrs,
          replacements: replacements,
          currentText: replacement,
          originalText: mark.attrs.originalText || entityText,
          displayText: replacement,
          entityColor: selectedColor,
        });

        // Create new text node with the updated mark
        const newText = state.schema.text(
          replacement,
          node.marks
            .filter((m) => m.type.name !== "coloredEntity")
            .concat(updatedMark)
        );

        // Replace the node in the document
        tr.replaceWith(pos, pos + node.nodeSize, newText);

        found = true;
        this.saveContentWithEntityChanges();
        return false;
      }
      return true;
    });

    if (found) {
      this.preventNextUpdate = true;
      this.editor.view.dispatch(tr);
    } else {
      console.warn(`Could not find entity ${entityId} in document model`);
    }
  },

  replaceEntityWithCustomText(entityId, customText, originalText) {
    console.log(`Replacing entity ${entityId} with custom text: ${customText}`);

    const entityElements = this.editor.view.dom.querySelectorAll(
      `.colored-entity[data-entity-id="${entityId}"]`
    );

    if (entityElements.length === 0) {
      console.warn(`Entity with ID ${entityId} not found in DOM`);
      return;
    }

    entityElements.forEach((el) => {
      el.textContent = customText;
    });

    const selectedColor = "#a8d1ff";

    this.pushEvent("entity-replace", {
      entity_id: entityId,
      replacement: customText,
      original: originalText,
      display_text: customText,
      custom_text: true,
      selected_color: selectedColor,
    });

    const { state } = this.editor;
    const { tr } = state;
    let found = false;

    state.doc.descendants((node, pos) => {
      if (found) return false;

      if (
        node.isText &&
        node.marks.some(
          (mark) =>
            mark.type.name === "coloredEntity" &&
            mark.attrs.entityId === entityId
        )
      ) {
        const mark = node.marks.find(
          (m) =>
            m.type.name === "coloredEntity" && m.attrs.entityId === entityId
        );

        let replacements = [...(mark.attrs.replacements || [])];

        if (!replacements.includes(originalText)) {
          replacements.push(originalText);
        }

        const updatedMark = mark.type.create({
          ...mark.attrs,
          replacements: replacements,
          currentText: customText,
          originalText: mark.attrs.originalText || originalText,
          displayText: customText,
          entityColor: selectedColor,
        });

        const newText = state.schema.text(
          customText,
          node.marks
            .filter((m) => m.type.name !== "coloredEntity")
            .concat(updatedMark)
        );

        tr.replaceWith(pos, pos + node.nodeSize, newText);

        found = true;
        this.saveContentWithEntityChanges();
        return false;
      }
      return true;
    });

    if (found) {
      this.preventNextUpdate = true;
      this.editor.view.dispatch(tr);
    } else {
      console.warn(
        `Could not find entity ${entityId} in ProseMirror document model`
      );
    }
  },

  markEntityForDeletion(entityId) {
    console.log(`Marking entity ${entityId} for deletion`);

    const entityEl = this.editor.view.dom.querySelector(
      `.colored-entity[data-entity-id="${entityId}"]`
    );
    if (entityEl) {
      entityEl.classList.add("marked-for-deletion");
      entityEl.setAttribute("data-deleted", "true");
    }

    const { state } = this.editor;
    const { tr } = state;
    let found = false;

    const updateEntityDeletionState = (node, pos) => {
      if (found) return;

      if (node.isText) {
        const marks = node.marks.filter(
          (mark) =>
            mark.type.name === "coloredEntity" &&
            mark.attrs.entityId === entityId
        );

        if (marks.length > 0) {
          const mark = marks[0];

          const updatedMark = mark.type.create({
            ...mark.attrs,
            deleted: true,
          });

          const newMarks = node.marks
            .filter((m) => m.type.name !== "coloredEntity")
            .concat(updatedMark);

          tr.addMark(pos, pos + node.nodeSize, updatedMark);
          found = true;

          this.saveContentWithEntityChanges();
          return;
        }
      }

      if (node.content && node.content.size) {
        node.descendants((child, childPos) => {
          if (!found && child.isText) {
            const marks = child.marks.filter(
              (mark) =>
                mark.type.name === "coloredEntity" &&
                mark.attrs.entityId === entityId
            );

            if (marks.length > 0) {
              const mark = marks[0];

              const updatedMark = mark.type.create({
                ...mark.attrs,
                deleted: true,
              });

              const absPos = pos + childPos;

              tr.addMark(absPos, absPos + child.nodeSize, updatedMark);
              found = true;

              this.saveContentWithEntityChanges();
            }
          }
          return !found;
        });
      }
    };

    updateEntityDeletionState(state.doc, 0);

    if (found) {
      this.preventNextUpdate = true;
      this.editor.view.dispatch(tr);
    } else {
      console.warn(
        `Could not find entity ${entityId} in ProseMirror document model for deletion`
      );
    }

    this.pushEvent("entity-deletion", { entity_id: entityId });
  },

  restoreEntityFromDeletion(entityId) {
    console.log(`Restoring entity ${entityId} from deletion state`);

    const entityEl = this.editor.view.dom.querySelector(
      `.colored-entity[data-entity-id="${entityId}"]`
    );
    if (entityEl) {
      entityEl.classList.remove("marked-for-deletion");
      entityEl.setAttribute("data-deleted", "false");

      entityEl.style.backgroundColor = "";
      entityEl.style.textDecoration = "";
      entityEl.style.color = "";
      entityEl.style.border = "";

      console.log(`DOM element for entity ${entityId} updated for restoration`);
    } else {
      console.warn(`Could not find DOM element for entity ${entityId}`);
    }

    const { state } = this.editor;
    const { tr } = state;
    let found = false;

    const updateEntityDeletionState = (node, pos) => {
      if (found) return;

      if (node.isText) {
        const marks = node.marks.filter(
          (mark) =>
            mark.type.name === "coloredEntity" &&
            mark.attrs.entityId === entityId
        );

        if (marks.length > 0) {
          const mark = marks[0];

          const updatedMark = mark.type.create({
            ...mark.attrs,
            deleted: false,
          });

          const newMarks = node.marks
            .filter((m) => m.type.name !== "coloredEntity")
            .concat(updatedMark);

          tr.addMark(pos, pos + node.nodeSize, updatedMark);
          found = true;

          this.saveContentWithEntityChanges();
          return;
        }
      }

      if (node.content && node.content.size) {
        node.descendants((child, childPos) => {
          if (!found && child.isText) {
            const marks = child.marks.filter(
              (mark) =>
                mark.type.name === "coloredEntity" &&
                mark.attrs.entityId === entityId
            );

            if (marks.length > 0) {
              const mark = marks[0];

              const updatedMark = mark.type.create({
                ...mark.attrs,
                deleted: false,
              });

              const absPos = pos + childPos;

              tr.addMark(absPos, absPos + child.nodeSize, updatedMark);
              found = true;

              this.saveContentWithEntityChanges();
            }
          }
          return !found;
        });
      }
    };

    updateEntityDeletionState(state.doc, 0);

    if (found) {
      console.log(`Successfully updated entity ${entityId} in document state`);
      this.preventNextUpdate = true;
      this.editor.view.dispatch(tr);

      this.saveContentWithEntityChanges();
    } else {
      console.warn(
        `Could not find entity ${entityId} in document model for restoration`
      );

      this.saveContentWithEntityChanges();
    }
  },

  saveContentWithEntityChanges() {
    clearTimeout(this.saveTimeout);
    this.saveTimeout = setTimeout(() => {
      const json = this.editor.getJSON();
      const text = this.editor.getText();

      this.contentUpdatePending = true;
      this.lastSavedContent = text;
      this.lastFormattedContent = JSON.stringify(json);

      this.pushEvent("content-updated", {
        content: text,
        formatted_content: JSON.stringify(json),
        persist_entities: true,
      });
    }, 50);
  },

  handleEntityStateChange(entityId, isDeleted) {
    const { state } = this.editor;
    const { tr } = state;
    let found = false;

    const updateEntityState = (node, pos) => {
      if (found) return;

      if (node.isText) {
        const marks = node.marks.filter(
          (mark) =>
            mark.type.name === "coloredEntity" &&
            mark.attrs.entityId === entityId
        );

        if (marks.length > 0) {
          const mark = marks[0];

          console.log(
            `Found entity ${entityId} in document, current deleted state: ${mark.attrs.deleted}`
          );

          const updatedMark = mark.type.create({
            ...mark.attrs,
            deleted: isDeleted,
          });

          tr.addMark(pos, pos + node.nodeSize, updatedMark);
          found = true;

          this.saveContentWithEntityChanges();
          return;
        }
      }

      if (node.content && node.content.size) {
        node.descendants((child, childPos) => {
          if (!found && child.isText) {
            const marks = child.marks.filter(
              (mark) =>
                mark.type.name === "coloredEntity" &&
                mark.attrs.entityId === entityId
            );

            if (marks.length > 0) {
              const mark = marks[0];

              console.log(
                `Found nested entity ${entityId}, current deleted state: ${mark.attrs.deleted}`
              );

              const updatedMark = mark.type.create({
                ...mark.attrs,
                deleted: isDeleted,
              });

              const absPos = pos + childPos;

              tr.addMark(absPos, absPos + child.nodeSize, updatedMark);
              found = true;

              this.saveContentWithEntityChanges();
            }
          }
          return !found;
        });
      }
    };

    updateEntityState(state.doc, 0);

    if (found) {
      console.log(
        `Successfully updated entity ${entityId} deletion state to ${isDeleted}`
      );
      this.preventNextUpdate = true;
      this.editor.view.dispatch(tr);
      return true;
    } else {
      console.warn(`Could not find entity ${entityId} in document model`);
      return false;
    }
  },

  updateEditorContent(content, formattedContent) {
    if (!this.editor) {
      console.warn("Editor not initialized yet, storing content for later");
      this.pendingContent = content;
      this.pendingFormattedContent = formattedContent;
      return;
    }

    this.preventNextUpdate = true;

    try {
      let parsedContent = null;
      if (formattedContent && formattedContent !== "null") {
        try {
          parsedContent =
            typeof formattedContent === "string"
              ? JSON.parse(formattedContent)
              : formattedContent;

          // Fix replacement issue by ensuring entity text content matches displayText
          if (parsedContent && parsedContent.content) {
            parsedContent = this.ensureEntityTextMatches(parsedContent);
          }
        } catch (e) {
          console.error("Error parsing formatted content:", e);
        }
      }

      setTimeout(() => {
        try {
          if (parsedContent && parsedContent.type === "doc") {
            this.editor.commands.setContent(parsedContent);
          } else if (content) {
            this.editor.commands.setContent(content);
          }

          this.content = content;
          this.lastSavedContent = content;
          this.lastFormattedContent =
            typeof formattedContent === "string"
              ? formattedContent
              : JSON.stringify(formattedContent);
        } catch (e) {
          console.error("Error setting editor content:", e);
        } finally {
          this.preventNextUpdate = false;
          this.applyDeletionStylingWithRetry(3);
        }
      }, 100);
    } catch (e) {
      console.error("Error in updateEditorContent:", e);
      this.preventNextUpdate = false;
    }

    this.applyDeletionStylingWithRetry(3);
  },

  ensureEntityTextMatches(docContent) {
    // Create a deep copy to avoid modifying the original
    const result = JSON.parse(JSON.stringify(docContent));

    const processNode = (node) => {
      // Check if this is a text node with coloredEntity marks
      if (node.text && node.marks && Array.isArray(node.marks)) {
        // Find any coloredEntity marks
        const entityMark = node.marks.find(
          (mark) => mark.type === "coloredEntity"
        );

        if (entityMark && entityMark.attrs) {
          // If displayText exists, make sure text matches it
          if (entityMark.attrs.displayText) {
            // Replace the text content with the displayText
            node.text = entityMark.attrs.displayText;
          }
          // If currentText exists but no displayText, use currentText
          else if (entityMark.attrs.currentText) {
            node.text = entityMark.attrs.currentText;
          }
        }
      }

      // Recursively process children
      if (node.content && Array.isArray(node.content)) {
        node.content.forEach(processNode);
      }
    };

    // Process all nodes in the document
    if (result.content && Array.isArray(result.content)) {
      result.content.forEach(processNode);
    }

    return result;
  },

  forceRefreshEditor(content, formattedContentStr) {
    if (!this.editor) {
      this.pendingContent = content;
      this.pendingFormattedContent = formattedContentStr;
      this.initEditor();
      return;
    }

    this.preventNextUpdate = true;

    try {
      let formattedContent = null;
      if (formattedContentStr && formattedContentStr !== "null") {
        try {
          formattedContent =
            typeof formattedContentStr === "string"
              ? JSON.parse(formattedContentStr)
              : formattedContentStr;

          // Fix replacement issue by ensuring entity text content matches displayText
          if (formattedContent && formattedContent.content) {
            formattedContent = this.ensureEntityTextMatches(formattedContent);
          }
        } catch (e) {
          console.error("Error parsing formatted content:", e);
        }
      }

      setTimeout(() => {
        try {
          this.editor.commands.clearContent();

          if (formattedContent && formattedContent.type === "doc") {
            this.editor.commands.setContent(formattedContent);
          } else if (content) {
            this.editor.commands.setContent(content);
          }

          this.content = content;
          this.lastSavedContent = content;
          this.lastFormattedContent = formattedContentStr;
        } catch (e) {
          console.error("Error in force refresh:", e);
        } finally {
          this.preventNextUpdate = false;
          this.applyDeletionStylingWithRetry(3);
        }
      }, 100);
    } catch (e) {
      console.error("Error in forceRefreshEditor:", e);
      this.preventNextUpdate = false;
    }

    this.applyDeletionStylingWithRetry(3);
  },

  createSimpleToolbar(container) {
    if (this.readOnly) {
      container.style.display = "none";
      return;
    }

    const buttons = [
      { command: "bold", icon: "B", tooltip: "Fett" },
      { command: "italic", icon: "I", tooltip: "Kursiv" },
      { command: "strike", icon: "S", tooltip: "Durchgestrichen" },
    ];

    buttons.forEach((btn) => {
      const button = document.createElement("button");
      button.innerHTML = btn.icon;
      button.title = btn.tooltip;
      button.classList.add("tiptap-toolbar-btn");

      button.addEventListener("click", () => {
        if (this.editor) {
          this.editor.chain().focus().toggleBold().run();
        }
      });

      container.appendChild(button);
    });
  },

  handleEntityEvents() {
    this.el.addEventListener("entityReplaced", (e) => {
      this.pushEvent("entity-replaced", {
        index: e.detail.nodeId,
        replacement: e.detail.replacement,
        switchedEntity: e.detail.switchedEntity || false,
      });
    });

    this.el.addEventListener("entityMarkedForDeletion", (e) => {
      this.pushEvent("entity-marked-for-deletion", {
        index: e.detail.nodeId,
      });
    });

    this.handleEvent("entity-restore", (e) => {
      console.log(`Received entity-restore event for ${e.entity_id}`);

      const success = this.handleEntityStateChange(e.entity_id, false);

      if (success) {
        this.restoreEntityFromDeletion(e.entity_id);
      } else {
        this.restoreEntityFromDeletion(e.entity_id);
      }

      this.applyDeletionStyling();
    });
  },

  applyDeletionStyling() {
    if (!this.editor || !this.editor.view || !this.editor.view.dom) return;

    console.log("Applying deletion styling to entities from document state");

    this.findDeletedEntitiesInState();

    const entityElements =
      this.editor.view.dom.querySelectorAll(".colored-entity");

    entityElements.forEach((el) => {
      const isDeleted = el.getAttribute("data-deleted") === "true";

      if (isDeleted) {
        el.classList.add("marked-for-deletion");

        el.style.backgroundColor = "#ffcccc";
        el.style.textDecoration = "line-through";
        el.style.color = "#999";
        el.style.border = "1px dashed #ff5555";

        console.log(
          `Applied deletion styling to entity: ${el.getAttribute(
            "data-entity-id"
          )}`
        );
      } else {
        el.classList.remove("marked-for-deletion");
      }
    });
  },

  findDeletedEntitiesInState() {
    if (!this.editor || !this.editor.state) return;

    const { doc } = this.editor.state;
    let foundDeleted = false;

    const processNode = (node) => {
      if (node.isText) {
        const deletedMarks = node.marks.filter(
          (mark) =>
            mark.type.name === "coloredEntity" && mark.attrs.deleted === true
        );

        if (deletedMarks.length > 0) {
          foundDeleted = true;
          console.log(
            `Found deleted entity in state: ${deletedMarks[0].attrs.entityId}`
          );

          setTimeout(() => {
            const entityId = deletedMarks[0].attrs.entityId;
            const entityEl = this.editor.view.dom.querySelector(
              `.colored-entity[data-entity-id="${entityId}"]`
            );

            if (entityEl) {
              entityEl.classList.add("marked-for-deletion");
              entityEl.style.backgroundColor = "#ffcccc";
              entityEl.style.textDecoration = "line-through";
              entityEl.style.color = "#999";
              entityEl.style.border = "1px dashed #ff5555";
              console.log(`Forced styling on entity: ${entityId}`);
            }
          }, 50);
        }
      }

      if (node.content) {
        node.content.forEach(processNode);
      }
    };

    processNode(doc);

    if (foundDeleted) {
      console.log("Found deleted entities in document state");
    }
  },

  applyDeletionStylingWithRetry(attempts) {
    this.applyDeletionStyling();

    if (attempts > 0) {
      for (let i = 0; i < attempts; i++) {
        setTimeout(() => {
          console.log(`Retry ${i + 1} for deletion styling`);
          this.applyDeletionStyling();
        }, (i + 1) * 200);
      }
    }
  },

  makeEntitiesClickable() {
    this.applyDeletionStyling();
  },
};

export default TipTapEditorOLD;
