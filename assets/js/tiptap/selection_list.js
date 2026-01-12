import { Node } from "@tiptap/core";

/**
 * SelectionList - A TipTap Node extension for rendering selection lists
 * This extension displays a list of entities that can be accepted or rejected
 */
export const SelectionList = Node.create({
  name: "selectionList",

  group: "block",

  // Make sure this node is considered an atom to prevent issues with selections
  atom: true,

  // Define the node's attributes
  addAttributes() {
    return {
      entityList: {
        default: [],
        parseHTML: (element) => {
          const entityListAttr = element.getAttribute("data-entity-list");
          if (entityListAttr) {
            try {
              return JSON.parse(entityListAttr);
            } catch (e) {
              window.elixirDebug?.error(
                `Error parsing entity list: ${e.message}`
              );
              return [];
            }
          }
          return [];
        },
        renderHTML: (attributes) => {
          if (!attributes.entityList) return {};
          try {
            return {
              "data-entity-list": JSON.stringify(attributes.entityList),
            };
          } catch (e) {
            window.elixirDebug?.error(
              `Error stringifying entity list: ${e.message}`
            );
            return {};
          }
        },
      },
    };
  },

  // HTML parsing rules
  parseHTML() {
    return [
      {
        tag: "div.selection-list-container",
      },
    ];
  },

  // Define how this node is rendered in HTML
  renderHTML({ HTMLAttributes, node }) {
    const entityList = node.attrs.entityList || [];

    // Debug info for rendering
    if (window.elixirDebug) {
      window.elixirDebug.info(
        `Rendering selection list with ${entityList.length} items`
      );
    }

    // Create container with data attributes
    return [
      "div",
      {
        class: "selection-list-container",
        "data-entity-count": entityList.length,
        ...HTMLAttributes,
      },
      0,
    ];
  },

  // Define custom rendering in the editor
  addNodeView() {
    return ({ node, editor, getPos }) => {
      // Helper function to translate entity categories from English to German
      const translateCategory = (category) => {
        const translations = {
          date: "Datum",
          number: "Nummer",
          identifier: "Identifikator",
          phrase: "Phrase",
          statement: "Aussage",
        };
        return translations[category?.toLowerCase()] || "Unbekannt";
      };

      // Create main container
      const dom = document.createElement("div");
      dom.className = "selection-list-container";

      // Add expanded class by default to show content
      dom.classList.add("expanded");

      // Create header
      const header = document.createElement("div");
      header.className = "selection-list-header";

      // Add toggle indicator
      const toggle = document.createElement("span");
      toggle.className = "selection-list-toggle";
      toggle.innerHTML = "▼";
      header.appendChild(toggle);

      // Add title
      const title = document.createElement("span");
      title.textContent = "Fehlende Entitäten aus der Eingabe";
      header.appendChild(title);

      // Create table for entities
      const table = document.createElement("table");
      table.className = "selection-list-table";

      // Add header row
      const thead = document.createElement("thead");
      const headerRow = document.createElement("tr");

      // Define columns
      ["Text", "Kategorie", "Aktionen"].forEach((text) => {
        const th = document.createElement("th");
        th.textContent = text;
        headerRow.appendChild(th);
      });

      thead.appendChild(headerRow);
      table.appendChild(thead);

      // Create table body
      const tbody = document.createElement("tbody");

      // Get entity list from node
      const entityList = node.attrs.entityList || [];

      // Add a row for each entity
      entityList.forEach((entity) => {
        const row = document.createElement("tr");

        // Apply classes based on entity state
        if (entity.deleted) {
          row.classList.add("deleted-entity");
        }
        if (entity.confirmed) {
          row.classList.add("confirmed-entity");
        }

        // Text cell
        const textCell = document.createElement("td");
        textCell.textContent = entity.originalText || "";
        row.appendChild(textCell);

        // Category cell
        const categoryCell = document.createElement("td");
        categoryCell.textContent = translateCategory(entity.entityCategory);
        row.appendChild(categoryCell);

        // Actions cell
        const actionsCell = document.createElement("td");

        // Accept button - always visible but disabled when confirmed
        const acceptBtn = document.createElement("button");
        acceptBtn.className = "entity-accept-btn";
        acceptBtn.textContent = "Fehlende Entität in Korrektur inkludieren";

        // Disable accept button if already confirmed
        if (entity.confirmed) {
          acceptBtn.classList.add("disabled");
          acceptBtn.disabled = true;
        }

        acceptBtn.addEventListener("click", (event) => {
          event.preventDefault();
          event.stopPropagation();

          console.log("Accept button clicked for entity:", entity.entityId);

          // Pass the specific entity ID in the custom event
          // This ensures we only update this specific entity
          if (window.liveSocket) {
            // Find a hook element we can use
            const editorHooks = document.querySelectorAll("[phx-hook]");
            let hookFound = false;

            // Try to find a hook to push the event through
            for (const hookElement of editorHooks) {
              if (
                hookElement._phxHook &&
                typeof hookElement._phxHook.pushEvent === "function"
              ) {
                console.log("Using hook to push event:", hookElement.id);
                hookElement._phxHook.pushEvent("selection-entity-update", {
                  entity_id: entity.entityId,
                  deleted: false,
                  confirmed: true,
                });
                hookFound = true;
                break;
              }
            }

            // Fallback: dispatch event to document
            if (!hookFound) {
              console.log("No hook found, using custom event");
              const customEvent = new CustomEvent(
                "haimeda:selection-entity-update",
                {
                  bubbles: true,
                  detail: {
                    entity_id: entity.entityId,
                    deleted: false,
                    confirmed: true,
                  },
                }
              );
              document.dispatchEvent(customEvent);
            }
          }
        });
        actionsCell.appendChild(acceptBtn);

        // Remove button - always visible but disabled when deleted
        const removeBtn = document.createElement("button");
        removeBtn.className = "entity-remove-btn";
        removeBtn.textContent = "Nicht in Korrektur inkludieren";

        // Disable remove button if already deleted
        if (entity.deleted) {
          removeBtn.classList.add("disabled");
          removeBtn.disabled = true;
        }

        removeBtn.addEventListener("click", (event) => {
          event.preventDefault();
          event.stopPropagation();

          console.log("Remove button clicked for entity:", entity.entityId);

          // Pass the specific entity ID in the custom event
          // This ensures we only update this specific entity
          if (window.liveSocket) {
            // Find a hook element we can use
            const editorHooks = document.querySelectorAll("[phx-hook]");
            let hookFound = false;

            // Try to find a hook to push the event through
            for (const hookElement of editorHooks) {
              if (
                hookElement._phxHook &&
                typeof hookElement._phxHook.pushEvent === "function"
              ) {
                console.log("Using hook to push event:", hookElement.id);
                hookElement._phxHook.pushEvent("selection-entity-update", {
                  entity_id: entity.entityId,
                  deleted: true,
                  confirmed: false,
                });
                hookFound = true;
                break;
              }
            }

            // Fallback: dispatch event to document
            if (!hookFound) {
              console.log("No hook found, using custom event");
              const customEvent = new CustomEvent(
                "haimeda:selection-entity-update",
                {
                  bubbles: true,
                  detail: {
                    entity_id: entity.entityId,
                    deleted: true,
                    confirmed: false,
                  },
                }
              );
              document.dispatchEvent(customEvent);
            }
          }
        });
        actionsCell.appendChild(removeBtn);

        row.appendChild(actionsCell);
        tbody.appendChild(row);
      });

      // Show message if no entities
      if (entityList.length === 0) {
        const emptyRow = document.createElement("tr");
        const emptyCell = document.createElement("td");
        emptyCell.colSpan = 3;
        emptyCell.textContent = "No selection items available";
        emptyCell.style.textAlign = "center";
        emptyCell.style.padding = "10px";
        emptyRow.appendChild(emptyCell);
        tbody.appendChild(emptyRow);
      }

      table.appendChild(tbody);

      // Add toggle behavior to header
      header.addEventListener("click", () => {
        dom.classList.toggle("expanded");
        toggle.innerHTML = dom.classList.contains("expanded") ? "▼" : "▶";
      });

      // Assemble the components
      dom.appendChild(header);
      dom.appendChild(table);

      return {
        dom,
        contentDOM: null, // No content DOM as this is a leaf node
        update(updatedNode) {
          if (updatedNode.type.name !== "selectionList") return false;

          // Update entity list if changed
          const updatedEntityList = updatedNode.attrs.entityList || [];

          // Clear tbody and rebuild it
          while (tbody.firstChild) {
            tbody.removeChild(tbody.firstChild);
          }

          // Rebuild rows with updated data
          updatedEntityList.forEach((entity) => {
            const row = document.createElement("tr");

            // Apply classes based on entity state
            if (entity.deleted) {
              row.classList.add("deleted-entity");
            }
            if (entity.confirmed) {
              row.classList.add("confirmed-entity");
            }

            // Text cell
            const textCell = document.createElement("td");
            textCell.textContent = entity.originalText || "";
            row.appendChild(textCell);

            // Category cell
            const categoryCell = document.createElement("td");
            categoryCell.textContent = translateCategory(entity.entityCategory);
            row.appendChild(categoryCell);

            // Actions cell
            const actionsCell = document.createElement("td");

            // Accept button - always visible but disabled when confirmed
            const acceptBtn = document.createElement("button");
            acceptBtn.className = "entity-accept-btn";
            acceptBtn.textContent = "Accept";

            // Disable accept button if already confirmed
            if (entity.confirmed) {
              acceptBtn.classList.add("disabled");
              acceptBtn.disabled = true;
            }

            acceptBtn.addEventListener("click", (event) => {
              event.preventDefault();
              event.stopPropagation();

              console.log("Accept button clicked for entity:", entity.entityId);

              // Pass the specific entity ID in the custom event
              // This ensures we only update this specific entity
              if (window.liveSocket) {
                // Find a hook element we can use
                const editorHooks = document.querySelectorAll("[phx-hook]");
                let hookFound = false;

                // Try to find a hook to push the event through
                for (const hookElement of editorHooks) {
                  if (
                    hookElement._phxHook &&
                    typeof hookElement._phxHook.pushEvent === "function"
                  ) {
                    console.log("Using hook to push event:", hookElement.id);
                    hookElement._phxHook.pushEvent("selection-entity-update", {
                      entity_id: entity.entityId,
                      deleted: false,
                      confirmed: true,
                    });
                    hookFound = true;
                    break;
                  }
                }

                // Fallback: dispatch event to document
                if (!hookFound) {
                  console.log("No hook found, using custom event");
                  const customEvent = new CustomEvent(
                    "haimeda:selection-entity-update",
                    {
                      bubbles: true,
                      detail: {
                        entity_id: entity.entityId,
                        deleted: false,
                        confirmed: true,
                      },
                    }
                  );
                  document.dispatchEvent(customEvent);
                }
              }
            });
            actionsCell.appendChild(acceptBtn);

            // Remove button - always visible but disabled when deleted
            const removeBtn = document.createElement("button");
            removeBtn.className = "entity-remove-btn";
            removeBtn.textContent = "Remove";

            // Disable remove button if already deleted
            if (entity.deleted) {
              removeBtn.classList.add("disabled");
              removeBtn.disabled = true;
            }

            removeBtn.addEventListener("click", (event) => {
              event.preventDefault();
              event.stopPropagation();

              console.log("Remove button clicked for entity:", entity.entityId);

              // Pass the specific entity ID in the custom event
              // This ensures we only update this specific entity
              if (window.liveSocket) {
                // Find a hook element we can use
                const editorHooks = document.querySelectorAll("[phx-hook]");
                let hookFound = false;

                // Try to find a hook to push the event through
                for (const hookElement of editorHooks) {
                  if (
                    hookElement._phxHook &&
                    typeof hookElement._phxHook.pushEvent === "function"
                  ) {
                    console.log("Using hook to push event:", hookElement.id);
                    hookElement._phxHook.pushEvent("selection-entity-update", {
                      entity_id: entity.entityId,
                      deleted: true,
                      confirmed: false,
                    });
                    hookFound = true;
                    break;
                  }
                }

                // Fallback: dispatch event to document
                if (!hookFound) {
                  console.log("No hook found, using custom event");
                  const customEvent = new CustomEvent(
                    "haimeda:selection-entity-update",
                    {
                      bubbles: true,
                      detail: {
                        entity_id: entity.entityId,
                        deleted: true,
                        confirmed: false,
                      },
                    }
                  );
                  document.dispatchEvent(customEvent);
                }
              }
            });
            actionsCell.appendChild(removeBtn);

            row.appendChild(actionsCell);
            tbody.appendChild(row);
          });

          // Show message if no entities
          if (updatedEntityList.length === 0) {
            const emptyRow = document.createElement("tr");
            const emptyCell = document.createElement("td");
            emptyCell.colSpan = 3;
            emptyCell.textContent = "No selection items available";
            emptyCell.style.textAlign = "center";
            emptyCell.style.padding = "10px";
            emptyRow.appendChild(emptyCell);
            tbody.appendChild(emptyRow);
          }

          return true;
        },
      };
    };
  },
});

// Add event handlers for selection list folding
function initSelectionListFolding() {
  // Find all selection list headers and add click handlers
  document.querySelectorAll(".selection-list-header").forEach((header) => {
    header.addEventListener("click", function () {
      // Find the parent container
      const container = this.closest(".selection-list-container");

      // Toggle the expanded class
      if (container) {
        container.classList.toggle("expanded");

        // Also toggle the rotation of the toggle icon if it exists
        const toggleIcon = this.querySelector(".selection-list-toggle");
        if (toggleIcon) {
          toggleIcon.style.transform = container.classList.contains("expanded")
            ? "rotate(90deg)"
            : "rotate(0deg)";
        }
      }
    });
  });
}

// Initialize folding when DOM is loaded
document.addEventListener("DOMContentLoaded", initSelectionListFolding);

// Also handle dynamic content by re-initializing when LiveView updates the DOM
document.addEventListener("phx:update", initSelectionListFolding);

export default SelectionList;
