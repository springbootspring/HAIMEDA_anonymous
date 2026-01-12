// File: tip_tap_entities.js
// Entity-related functionality for the TipTap editor
import { Mark } from "@tiptap/core";

// Improved mark for colored entities
export const ColoredEntity = Mark.create({
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
          // Fix: Return data-deleted attribute for both true and false cases
          return { "data-deleted": attributes.deleted ? "true" : "false" };
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
    // Ensure the deleted status is properly used regardless of how it's provided
    const isDeleted =
      HTMLAttributes.deleted === true ||
      HTMLAttributes["data-deleted"] === "true";

    // Choose background color based on deletion status
    const bgColor = isDeleted
      ? "#ffcccc"
      : HTMLAttributes.entityColor || "#d8b5ff";

    // Build style string with appropriate styling for deleted entities
    const style = [
      `background-color: ${bgColor};`,
      isDeleted
        ? "text-decoration: line-through; color: #999; border: 1px dashed #ff5555;"
        : "",
    ].join(" ");

    // Add marked-for-deletion class when deleted
    const entityClass = isDeleted
      ? "colored-entity marked-for-deletion"
      : "colored-entity";

    // Ensure data-deleted attribute is always set explicitly
    return [
      "span",
      {
        ...this.options.HTMLAttributes,
        ...HTMLAttributes,
        style,
        class: entityClass,
        "data-entity-id": HTMLAttributes.entityId || `entity-${Date.now()}`,
        "data-entity-type": HTMLAttributes.entityType || "unknown",
        "data-deleted": isDeleted ? "true" : "false",
        "data-boundary": "true",
        "data-word-break": "normal",
        "data-box-decoration-break": "clone",
      },
      0,
    ];
  },

  // Add special handling for hardbreaks and entity boundaries
  addKeyboardShortcuts() {
    return {
      // Handle enter key to ensure proper spacing after entities
      Enter: ({ editor }) => {
        // Check if cursor is inside or adjacent to an entity
        const isAtEntityBoundary = this.isAtEntityBoundary(editor);

        if (isAtEntityBoundary) {
          // Insert a regular newline character instead of hardBreak
          editor
            .chain()
            // .insertContent([
            //   { type: "text", text: "\n" },
            //   { type: "text", text: "" },
            // ])
            .run();
          return true;
        }
        return false;
      },
    };
  },

  // Helper method to check if cursor is at entity boundary
  isAtEntityBoundary(editor) {
    const { state } = editor;
    const { selection } = state;
    const { $from, $to } = selection;

    // Check if any marks at cursor position are coloredEntity
    const fromMarks = $from.marks();
    const toMarks = $to.marks();

    return (
      fromMarks.some((mark) => mark.type.name === "coloredEntity") ||
      toMarks.some((mark) => mark.type.name === "coloredEntity")
    );
  },
});

// Entity handling methods for the TipTap editor
export const EntityHandlingMethods = {
  setupEntityObserver() {
    this.entityOverlay = document.createElement("div");
    this.entityOverlay.className = "entity-controls-overlay";
    document.body.appendChild(this.entityOverlay);

    // Change from click to mousedown event (fires earlier) and add capturing phase
    this.editor.view.dom.addEventListener(
      "mousedown",
      (e) => {
        const entity = e.target.closest(".colored-entity");
        if (entity) {
          e.preventDefault(); // Prevent default to ensure the click is captured
          e.stopPropagation(); // Stop propagation to prevent any parent handlers

          // Add a small delay to ensure we don't have competing events
          setTimeout(() => {
            this.showEntityOverlay(entity);
          }, 10);
        }
      },
      true // Add capturing phase (true) to capture events before they bubble
    );

    // Keep the existing click handler as backup
    this.editor.view.dom.addEventListener("click", (e) => {
      const entity = e.target.closest(".colored-entity");
      if (entity) {
        e.preventDefault();
        e.stopPropagation();
      }
    });

    // Add additional touchstart event for better mobile support
    this.editor.view.dom.addEventListener(
      "touchstart",
      (e) => {
        const entity = e.target.closest(".colored-entity");
        if (entity) {
          e.preventDefault();
          e.stopPropagation();

          // Delay to prevent unintended double triggers
          setTimeout(() => {
            this.showEntityOverlay(entity);
          }, 10);
        }
      },
      { passive: false }
    );

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

    // Add handler for selection list entity updates
    this.editor.view.dom.addEventListener("selection-entity-update", (e) => {
      const entityId = e.detail.entity_id;
      const deleted = e.detail.deleted;
      const confirmed = e.detail.confirmed;

      console.log(
        `Selection entity update: ${entityId}, deleted: ${deleted}, confirmed: ${confirmed}`
      );

      // Dispatch event to LiveView
      this.pushEvent("selection-entity-update", {
        entity_id: entityId,
        deleted: deleted,
        confirmed: confirmed,
      });
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

    // Highlight the entity to make it clear which one is selected
    if (this.activeEntityElement && this.activeEntityElement !== entity) {
      this.activeEntityElement.style.boxShadow = "";
    }

    entity.style.boxShadow = "0 0 0 2px #9370db";
    this.activeEntityElement = entity;

    const entityId = entity.getAttribute("data-entity-id");
    const entityText = entity.textContent;

    // --- merged replacements logic ---
    const stateRepl = this.getEntityReplacementsFromState(entityId) || [];
    const cacheRepl = this.entityReplacementsCache[entityId] || [];
    let replacements = Array.from(new Set([...stateRepl, ...cacheRepl]));
    // --- end merge ---

    console.log(
      `Replacements for entity ${entityId}: ${JSON.stringify(replacements)}`
    );

    // filter out the currently displayed text
    const filteredReplacements = replacements.filter((r) => r !== entityText);
    console.log(
      `Filtered replacements: ${JSON.stringify(filteredReplacements)}`
    );

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
        // Update document model
        // this.handleEntityStateChange(entityId, false);

        this.pushEvent("entity-restore", { entity_id: entityId });
        // Update DOM element immediately for visual feedback
        entity.classList.remove("marked-for-deletion");
        entity.setAttribute("data-deleted", "false");
        entity.style.backgroundColor = "";
        entity.style.textDecoration = "";
        entity.style.color = "";
        entity.style.border = "";

        // Notify server about restoration

        console.log(`Restoring entity from deletion: ${entityId}`);
      } else {
        // Update document model
        // this.handleEntityStateChange(entityId, true);
        this.pushEvent("entity-deletion", { entity_id: entityId });
        // Update DOM element immediately for visual feedback
        entity.classList.add("marked-for-deletion");
        entity.setAttribute("data-deleted", "true");
        entity.style.backgroundColor = "#ffcccc";
        entity.style.textDecoration = "line-through";
        entity.style.color = "#999";
        entity.style.border = "1px dashed #ff5555";

        // Notify server about deletion

        console.log(`Marking entity for deletion: ${entityId}`);
      }

      // Save content to ensure changes persist
      // this.saveContentWithEntityChanges();

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

      // Remove highlight from active entity
      if (this.activeEntityElement) {
        this.activeEntityElement.style.boxShadow = "";
      }

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

        // Store updated replacements in our cache for immediate use
        this.entityReplacementsCache[entityId] = replacements;

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

    // Re-apply styling and click hooks so the new text shows up instantly
    setTimeout(() => {
      this.applyDeletionStyling();
      this.makeEntitiesClickable();
    }, 0);
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

        // Get existing replacements from both the mark and our cache
        let replacements = [
          ...(mark.attrs.replacements || []),
          ...(this.entityReplacementsCache[entityId] || []),
        ];

        // Add the original text to replacements if not already there
        if (!replacements.includes(originalText)) {
          replacements.push(originalText);
        }

        // Deduplicate the combined list
        replacements = [...new Set(replacements)].filter(
          (r) => r !== "" && r !== customText
        ); // Remove empty strings and the new custom text

        console.log(
          `Updated replacements list: ${JSON.stringify(replacements)}`
        );

        // Store updated replacements in our cache for immediate use
        this.entityReplacementsCache[entityId] = replacements;

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

    // Re-apply styling and click hooks so the new text shows up instantly
    setTimeout(() => {
      this.applyDeletionStyling();
      this.makeEntitiesClickable();
    }, 0);
  },

  markEntityForDeletion(entityId) {
    console.log(`Marking entity ${entityId} for deletion`);

    // Update DOM elements first for immediate feedback
    const entityElements = this.editor.view.dom.querySelectorAll(
      `.colored-entity[data-entity-id="${entityId}"]`
    );

    this.pushEvent("entity-deletion", { entity_id: entityId });

    entityElements.forEach((el) => {
      el.classList.add("marked-for-deletion");
      el.setAttribute("data-deleted", "true");
      el.style.backgroundColor = "#ffcccc";
      el.style.textDecoration = "line-through";
      el.style.color = "#999";
      el.style.border = "1px dashed #ff5555";
    });

    // Update document model
    this.handleEntityStateChange(entityId, true);

    // Always push event

    // Save content to ensure changes are sent to the server
    this.saveContentWithEntityChanges();
  },

  restoreEntityFromDeletion(entityId) {
    console.log(`Restoring entity ${entityId} from deletion state`);

    // Update DOM elements first for immediate feedback
    const entityElements = this.editor.view.dom.querySelectorAll(
      `.colored-entity[data-entity-id="${entityId}"]`
    );

    this.handleEntityStateChange(entityId, false);
    // this.pushEvent("entity-restore", { entity_id: entityId });

    entityElements.forEach((el) => {
      el.classList.remove("marked-for-deletion");
      el.setAttribute("data-deleted", "false");
      el.style.backgroundColor = "";
      el.style.textDecoration = "";
      el.style.color = "";
      el.style.border = "";
    });

    // Update document model
    //this.handleEntityStateChange(entityId, false);

    // Always push event

    // Save content to ensure changes are sent to the server
    //this.saveContentWithEntityChanges();
  },

  handleEntityStateChange(entityId, isDeleted) {
    const { state } = this.editor;
    const { tr } = state;
    let foundCount = 0;
    let hasUpdates = false;

    // First pass - identify all occurrences of this entity ID
    const entityPositions = [];

    state.doc.descendants((node, pos) => {
      if (node.isText) {
        // Check for coloredEntity marks with matching entityId
        node.marks.forEach((mark) => {
          if (
            mark.type.name === "coloredEntity" &&
            mark.attrs.entityId === entityId
          ) {
            entityPositions.push({
              pos,
              nodeSize: node.nodeSize,
              text: node.text,
            });
          }
        });
      }
      // Continue traversing
      return true;
    });

    // Log what we found for debugging
    window.elixirDebug?.info(
      `Found ${
        entityPositions.length
      } occurrences of entity ${entityId} to mark as ${
        isDeleted ? "deleted" : "not deleted"
      }`
    );

    // Second pass - update each occurrence with the new mark
    for (const { pos, nodeSize, text } of entityPositions) {
      // Find the specific mark in this node
      const node = state.doc.nodeAt(pos);
      if (!node) continue;

      const mark = node.marks.find(
        (m) => m.type.name === "coloredEntity" && m.attrs.entityId === entityId
      );

      if (mark) {
        // Create updated mark with new deleted state
        const updatedMark = mark.type.create({
          ...mark.attrs,
          deleted: isDeleted,
        });

        // Remove old mark and add updated mark for this range
        tr.removeMark(pos, pos + nodeSize, mark.type);
        tr.addMark(pos, pos + nodeSize, updatedMark);

        foundCount++;
        hasUpdates = true;
      }
    }

    if (hasUpdates) {
      this.preventNextUpdate = true;
      this.editor.view.dispatch(tr);
      window.elixirDebug?.info(
        `Updated ${foundCount} instances of entity ${entityId} to deleted=${isDeleted}`
      );

      // --- PUSH DELETE/RESTORE EVENT IMMEDIATELY ---
      if (isDeleted) {
        this.pushEvent("entity-deletion", { entity_id: entityId });
      } else {
        this.pushEvent("entity-restore", { entity_id: entityId });
      }
      // ------------------------------------------------

      // Schedule a save of the content after entity state change
      this.saveContentWithEntityChanges();
      return true;
    } else {
      console.warn(`Could not find entity ${entityId} in document model`);
      return false;
    }
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

    // Get all deleted entities from the document state
    const deletedEntities = this.findDeletedEntitiesInState();

    if (deletedEntities.length > 0) {
      window.elixirDebug?.info(
        `Found ${deletedEntities.length} deleted entities in document state`
      );

      // Apply styling to all matching DOM elements
      deletedEntities.forEach((entityId) => {
        const entityElements = this.editor.view.dom.querySelectorAll(
          `.colored-entity[data-entity-id="${entityId}"]`
        );

        if (entityElements.length > 0) {
          window.elixirDebug?.info(
            `Applying deletion styling to ${entityElements.length} DOM elements for entity ${entityId}`
          );

          entityElements.forEach((el) => {
            el.classList.add("marked-for-deletion");
            el.setAttribute("data-deleted", "true");
            el.style.backgroundColor = "#ffcccc";
            el.style.textDecoration = "line-through";
            el.style.color = "#999";
            el.style.border = "1px dashed #ff5555";
          });
        }
      });
    }

    // Also check for any DOM elements with data-deleted="true" that might have been missed
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
      } else {
        el.classList.remove("marked-for-deletion");
      }
    });
  },

  // Add this to support retries on initial load
  applyDeletionStylingWithRetry(attempts = 3) {
    this.applyDeletionStyling();
    if (attempts > 1) {
      setTimeout(() => {
        this.applyDeletionStylingWithRetry(attempts - 1);
      }, 100);
    }
  },

  // Improve the function to return an array of entity IDs
  findDeletedEntitiesInState() {
    if (!this.editor || !this.editor.state) return [];

    const { doc } = this.editor.state;
    const deletedEntityIds = [];

    // Find all deleted entities in the document
    doc.descendants((node, pos) => {
      if (node.isText) {
        node.marks.forEach((mark) => {
          if (
            mark.type.name === "coloredEntity" &&
            mark.attrs.deleted === true
          ) {
            const entityId = mark.attrs.entityId;
            if (!deletedEntityIds.includes(entityId)) {
              deletedEntityIds.push(entityId);
              window.elixirDebug?.info(
                `Found deleted entity in state: ${entityId}`
              );
            }
          }
        });
      }
    });

    return deletedEntityIds;
  },
};
