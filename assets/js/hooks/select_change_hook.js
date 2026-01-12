export const SelectChangeHook = {
  mounted() {
    this.el.addEventListener("change", (e) => {
      // Directly push the event to ensure it's captured
      console.log(
        "Select changed:",
        this.el.value,
        "for index:",
        this.el.getAttribute("phx-value-index")
      );

      // Get the parameters from the element
      const tabId = this.el.getAttribute("phx-value-id");
      const index = this.el.getAttribute("phx-value-index");
      const value = this.el.value;

      // Push the event manually to ensure it's sent
      this.pushEvent("update-person-statement-id", {
        id: tabId,
        index: index,
        value: value,
      });
    });
  },
};
