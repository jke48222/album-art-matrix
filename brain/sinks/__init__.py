class FrameSink:
    """Somewhere pixels go. show() takes the WB-corrected RGB888 bytes for the
    panel, plus the pre-white-balance PIL image for previews (WB compensates
    panel hardware, so on a computer screen it just looks orange)."""

    def show(self, rgb888: bytes, pre_wb_img=None):
        raise NotImplementedError
