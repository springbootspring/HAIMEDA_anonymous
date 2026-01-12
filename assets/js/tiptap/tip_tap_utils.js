// File: tip_tap_utils.js
// Utility functions for the TipTap editor

/**
 * Ensures entities render properly by adding necessary spacers
 * between entities and at boundaries
 */
export function ensureEntitiesRender(docContent) {
  // Create a deep copy to avoid modifying the original
  const result = JSON.parse(JSON.stringify(docContent));

  // Process each paragraph node
  if (result.content && Array.isArray(result.content)) {
    result.content.forEach((paragraph) => {
      if (
        paragraph.type === "paragraph" &&
        paragraph.content &&
        Array.isArray(paragraph.content)
      ) {
        // Insert zero-width spaces or spacers between adjacent entities
        const newContent = [];

        // Add zero-width space at the beginning if needed
        if (paragraph.content.length > 0) {
          const firstNode = paragraph.content[0];
          if (
            firstNode &&
            firstNode.marks &&
            firstNode.marks.some((m) => m.type === "coloredEntity")
          ) {
            // Always add a zero-width space before the entity at paragraph start
            newContent.push({
              text: "\u200B", // Zero-width space
              type: "text",
            });
          }
        }

        // Process all content nodes
        paragraph.content.forEach((node, index) => {
          // Add the current node
          newContent.push(node);

          // Check if we need to add a separator between this and the next node
          if (index < paragraph.content.length - 1) {
            const currentNode = node;
            const nextNode = paragraph.content[index + 1];

            // If current node is a hardBreak, ensure there's a visible space after it
            // This is critical for entity rendering
            if (currentNode.type === "hardBreak") {
              // Always add a space after hardbreak for consistent entity rendering
              // newContent.push({
              //   text: " ", // Visible space after hardbreak
              //   type: "text",
              // });

              // If the next node is an entity, add an additional zero-width space
              if (
                nextNode.marks &&
                nextNode.marks.some((m) => m.type === "coloredEntity")
              ) {
                // newContent.push({
                //   text: "\u200B", // Zero-width space before entity
                //   type: "text",
                // });
              }
            }
            // If both current and next nodes have entity marks, add a zero-width space between them
            else if (
              currentNode.marks &&
              currentNode.marks.some((m) => m.type === "coloredEntity") &&
              nextNode.marks &&
              nextNode.marks.some((m) => m.type === "coloredEntity")
            ) {
              // newContent.push({
              //   text: "\u200B", // Zero-width space as separator
              //   type: "text",
              // });
            }
            // Also add space after entity even if next node is plain text
            else if (
              currentNode.marks &&
              currentNode.marks.some((m) => m.type === "coloredEntity") &&
              nextNode.type === "text" &&
              (!nextNode.text || nextNode.text.trim() === "")
            ) {
              // If next node is empty text, insert a space to help with entity boundaries
              // newContent.push({
              //   text: "\u200B",
              //   type: "text",
              // });
            }
            // Handle case where next node is hardBreak right after an entity
            else if (
              currentNode.marks &&
              currentNode.marks.some((m) => m.type === "coloredEntity") &&
              nextNode.type === "hardBreak"
            ) {
              // Add a zero-width space after entity before hardbreak
              // newContent.push({
              //   text: "\u200B",
              //   type: "text",
              // });
            }
          }
        });

        // Add a space node at the end if needed
        if (paragraph.content.length > 0) {
          const lastNode = paragraph.content[paragraph.content.length - 1];
          if (
            lastNode &&
            lastNode.marks &&
            lastNode.marks.some((m) => m.type === "coloredEntity")
          ) {
            // Add a zero-width space after the entity to ensure rendering
            // newContent.push({
            //   text: "\u200B",
            //   type: "text",
            // });
          }
        }

        // Replace the paragraph content with our processed content
        paragraph.content = newContent;
      }
    });
  }

  return result;
}

/**
 * Ensures entity text matches the appropriate display or current text
 * in the document content
 */
export function ensureEntityTextMatches(docContent) {
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
}

/**
 * Creates a new entity in TipTap format
 * @param {string} text - The entity text
 * @param {string} entityType - Type of entity
 * @param {string} entityId - Unique ID for the entity
 * @param {string} entityColor - Background color for the entity
 * @param {Array} replacements - Alternative replacements for the entity
 * @returns {Object} A TipTap format entity node
 */
export function createEntityNode(
  text,
  entityType = "entity",
  entityId = null,
  entityColor = "#d8b5ff",
  replacements = []
) {
  // Generate an ID if none provided
  const id =
    entityId || `entity-${Date.now()}-${Math.floor(Math.random() * 1000)}`;

  // Create the entity node with marks
  return {
    type: "text",
    text: text,
    marks: [
      {
        type: "coloredEntity",
        attrs: {
          entityId: id,
          entityType: entityType,
          entityColor: entityColor,
          originalText: text,
          currentText: text,
          displayText: text,
          replacements: Array.isArray(replacements) ? replacements : [],
          deleted: false,
        },
      },
    ],
  };
}

/**
 * Creates a complete TipTap document with an entity at the specified position
 * @param {string} text - The full text content
 * @param {number} position - Position to insert the entity
 * @param {string} entityText - Text for the entity
 * @param {Array} replacements - Replacement options for the entity
 * @param {string} entityColor - Background color for the entity
 * @returns {Object} A complete TipTap document object
 */
export function createDocumentWithEntity(
  text,
  position,
  entityText,
  replacements = [],
  entityColor = "#d8b5ff"
) {
  // Split the text at the position
  const beforeText = text.substring(0, position);
  const afterText = text.substring(position + entityText.length);

  // Create the entity node
  const entityNode = createEntityNode(
    entityText,
    "entity",
    null,
    entityColor,
    replacements
  );

  // Build the paragraph content
  const paragraphContent = [];

  // Add text before entity if exists
  if (beforeText) {
    // Check if beforeText ends with a newline character
    if (beforeText.endsWith("\n")) {
      // Remove the newline
      const textWithoutNewline = beforeText.slice(0, -1);

      if (textWithoutNewline) {
        paragraphContent.push({ type: "text", text: textWithoutNewline });
      }

      // Add proper hardBreak
      paragraphContent.push({ type: "hardBreak" });
      // Add space after hardBreak
      // paragraphContent.push({ type: "text", text: " " });

      // Add zero-width space for better entity rendering
      // paragraphContent.push({ type: "text", text: "\u200B" });
    } else {
      paragraphContent.push({ type: "text", text: beforeText });
    }
  } else {
    // Add a zero-width space at the beginning for better rendering
    paragraphContent.push({ type: "text", text: "\u200B" });
  }

  // Add the entity
  paragraphContent.push(entityNode);

  // Add text after entity if exists
  if (afterText) {
    // Check if afterText starts with a newline character
    if (afterText.startsWith("\n")) {
      // Add zero-width space after entity
      // paragraphContent.push({ type: "text", text: "\u200B" });

      // Add proper hardBreak
      paragraphContent.push({ type: "hardBreak" });
      // Add space after hardBreak
      // paragraphContent.push({ type: "text", text: " " });

      // Add remaining text without the newline
      const textWithoutNewline = afterText.slice(1);
      if (textWithoutNewline) {
        paragraphContent.push({ type: "text", text: textWithoutNewline });
      }
    } else {
      paragraphContent.push({ type: "text", text: afterText });
    }
  } else {
    // Add a zero-width space at the end for better rendering
    // paragraphContent.push({ type: "text", text: "\u200B" });
  }

  // Return the complete document structure
  return {
    type: "doc",
    content: [
      {
        type: "paragraph",
        content: paragraphContent,
      },
    ],
  };
}

/**
 * Extracts entities from TipTap formatted content
 * @param {Object} formattedContent - TipTap formatted content
 * @returns {Array} List of entities with their attributes
 */
export function extractEntitiesFromContent(formattedContent) {
  const entities = [];

  // Return empty array for invalid input
  if (!formattedContent || typeof formattedContent !== "object") {
    return entities;
  }

  const processNode = (node, path = "") => {
    // Check if this is a text node with coloredEntity marks
    if (node.text && node.marks && Array.isArray(node.marks)) {
      // Find any coloredEntity marks
      const entityMark = node.marks.find(
        (mark) => mark.type === "coloredEntity"
      );

      if (entityMark && entityMark.attrs) {
        entities.push({
          id: entityMark.attrs.entityId || `entity-${Date.now()}`,
          text: node.text,
          type: entityMark.attrs.entityType || "unknown",
          color: entityMark.attrs.entityColor || "#d8b5ff",
          deleted: entityMark.attrs.deleted || false,
          originalText: entityMark.attrs.originalText || node.text,
          currentText: entityMark.attrs.currentText || node.text,
          displayText: entityMark.attrs.displayText || node.text,
          replacements: entityMark.attrs.replacements || [],
          path: path, // Keep track of the path in the document for later reference
        });
      }
    }

    // Recursively process children
    if (node.content && Array.isArray(node.content)) {
      node.content.forEach((childNode, index) => {
        processNode(childNode, `${path}.${index}`);
      });
    }
  };

  // Start processing from the root
  processNode(formattedContent);

  return entities;
}

/**
 * Sanitizes formatted content to ensure it has valid structure
 * Fixes common issues that occur during MongoDB storage/retrieval
 * @param {Object} docContent - TipTap formatted content
 * @returns {Object} - Sanitized content
 */
export function sanitizeFormattedContent(docContent) {
  if (!docContent || typeof docContent !== "object") {
    return createDefaultDocument("");
  }

  try {
    // Create a deep copy to avoid modifying the original
    const result = JSON.parse(JSON.stringify(docContent));

    // Validate overall document structure
    if (!result.type || !result.content || !Array.isArray(result.content)) {
      console.warn("Invalid document structure", result);
      return createDefaultDocument("");
    }

    // Process each node in the content
    result.content = result.content.map((node) => {
      // Handle selection lists
      if (node.type === "list" && node.marks && Array.isArray(node.marks)) {
        const selectionListMark = node.marks.find(
          (mark) =>
            mark.type === "coloredEntity" &&
            mark.attrs &&
            mark.attrs.entityType === "selection_list"
        );

        if (selectionListMark) {
          console.log(
            "Converting list to selectionList node",
            selectionListMark.attrs.entityList
          );
          // Convert to a proper selectionList node
          return {
            type: "selectionList",
            attrs: {
              entityList: selectionListMark.attrs.entityList || [],
            },
          };
        }
      }

      // Handle direct selectionList type (already converted)
      if (
        node.type === "selectionList" &&
        node.attrs &&
        node.attrs.entityList
      ) {
        console.log("Found existing selectionList node", node.attrs.entityList);
        return node;
      }

      // Handle paragraphs
      if (
        node.type === "paragraph" &&
        node.content &&
        Array.isArray(node.content)
      ) {
        // IMPORTANT FIX: Don't filter out hardBreak nodes - keep them!
        node.content = node.content
          .map((childNode) => {
            // Remove nodes with typos in properties (like "ttext" instead of "text")
            if (childNode.ttext !== undefined && childNode.text === undefined) {
              // Fix typo by transferring value
              childNode.text = childNode.ttext;
              delete childNode.ttext;
            }
            return childNode;
          })
          .filter((childNode) => {
            // Keep valid text nodes AND hardBreak nodes
            return (
              (childNode &&
                childNode.type === "text" &&
                typeof childNode.text === "string") ||
              (childNode && childNode.type === "hardBreak")
            );
          });

        // Simplify the spacing between nodes - but PRESERVE hardBreaks
        ensureProperSpacingAroundHardBreaks(node.content);
      }

      return node;
    });

    // Apply additional entity rendering fixes
    return ensureEntitiesRender(result);
  } catch (e) {
    console.error("Error sanitizing formatted content:", e);
    return createDefaultDocument("");
  }
}

/**
 * Ensures proper spacing around hardBreak nodes WITHOUT removing them
 * @param {Array} contentNodes - Array of content nodes
 */
function ensureProperSpacingAroundHardBreaks(contentNodes) {
  for (let i = 0; i < contentNodes.length; i++) {
    // Check if this is a hardBreak node
    if (contentNodes[i].type === "hardBreak") {
      // If there's no space node after the hardBreak, add one
      if (
        i < contentNodes.length - 1 &&
        !(
          contentNodes[i + 1].type === "text" &&
          contentNodes[i + 1].text === " "
        )
      ) {
        // contentNodes.splice(i + 1, 0, {
        //   type: "text",
        //   text: " ",
        // });
        // Skip the inserted node
        i++;
      } else if (i === contentNodes.length - 1) {
        // If hardBreak is the last node, add a space after it
        // contentNodes.push({
        //   type: "text",
        //   text: " ",
        // });
        i++; // Skip the inserted node
      }
    }

    // Continue with existing entity handling...
  }
}

/**
 * Creates a default empty document structure
 * @param {string} text - Text to include in the document
 * @returns {Object} - Default document structure
 */
function createDefaultDocument(text = "") {
  return {
    type: "doc",
    content: [
      {
        type: "paragraph",
        content: [
          {
            type: "text",
            text: text,
          },
        ],
      },
    ],
  };
}
