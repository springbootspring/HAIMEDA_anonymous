/**
 * Editor communication utilities
 * Functions to help coordinate editor state between Phoenix LiveView and client
 */

// Global hook instance that allows pushing events to LiveView
let liveViewHook = null;

/**
 * Set up the hook instance for communication
 * @param {Object} hook - The LiveView hook instance
 */
export function setHook(hook) {
  liveViewHook = hook;
  console.log("EditorComm: LiveView hook set");
}

/**
 * Push an event to LiveView
 * @param {string} event - The event name
 * @param {Object} payload - The event payload
 * @returns {boolean} Whether the event was successfully pushed
 */
export function pushEvent(event, payload) {
  if (liveViewHook && liveViewHook.pushEvent) {
    console.log(`EditorComm: Pushing event '${event}' with payload:`, payload);
    liveViewHook.pushEvent(event, payload);
    return true;
  } else {
    console.error(`EditorComm: Cannot push event '${event}' - no active hook`);
    return false;
  }
}

/**
 * Force refresh a TipTap editor with new content
 * @param {string} editorId - The ID of the editor to refresh
 * @param {string} content - Plain text content
 * @param {string} formattedContent - JSON string of formatted content
 * @returns {boolean} Whether the refresh was successful
 */
export function forceRefreshEditor(editorId, content, formattedContent) {
  // Find the editor's hook element
  const editorElem = document.getElementById(editorId);

  if (!editorElem) {
    console.warn(`EditorComm: Cannot find editor element with ID: ${editorId}`);
    return false;
  }

  // Check if element has a component hook attached
  if (editorElem._component && editorElem._component.updateContent) {
    console.log(`EditorComm: Refreshing editor ${editorId} with new content`);
    editorElem._component.updateContent(content, formattedContent);
    return true;
  } else {
    console.warn(
      `EditorComm: Editor ${editorId} found but has no component hook`
    );
    return false;
  }
}

/**
 * Attach editor component reference for future use
 * @param {string} editorId - The ID of the editor
 * @param {Object} component - The editor component reference
 * @returns {boolean} Whether the component was successfully attached
 */
export function attachEditorComponent(editorId, component) {
  const editorElem = document.getElementById(editorId);
  if (editorElem) {
    editorElem._component = component;
    console.log(`EditorComm: Attached component to editor ${editorId}`);
    return true;
  }
  return false;
}

/**
 * Update an editor's read-only state
 * @param {string} editorId - The ID of the editor to update
 * @param {boolean} readOnly - Whether the editor should be read-only
 */
export function setEditorReadOnly(editorId, readOnly) {
  const hook = window.liveSocket.getHookById(editorId);
  if (hook && hook.editor) {
    hook.editor.setEditable(!readOnly);
  }
}

/**
 * Get the current editor content
 * @param {string} editorId - The ID of the editor
 * @returns {Object} Both plain text and formatted content
 */
export function getEditorContent(editorId) {
  const hook = window.liveSocket.getHookById(editorId);
  if (hook && hook.editor) {
    return {
      plainContent: hook.editor.getText(),
      formattedContent: hook.editor.getJSON(),
    };
  }
  return null;
}
