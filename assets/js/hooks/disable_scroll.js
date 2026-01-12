const DisableScroll = {
  mounted() {
    // Disabled to fix white bar issue
    // No longer disabling scrolling to allow native scrollbars to appear
  },
  destroyed() {
    // No cleanup needed since we're not modifying scroll behavior
  },
};

export { DisableScroll };
