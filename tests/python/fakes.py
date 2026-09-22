"""Stand-ins for the S3 HTTP layer."""


def s3_listing(keys: list[str]) -> str:
    items = "".join(f"<Contents><Key>{k}</Key><Size>1</Size></Contents>" for k in keys)
    return (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
        f"<Name>bucket</Name>{items}</ListBucketResult>"
    )


class FakeResponse:
    def __init__(self, text: str = "", content: bytes = b""):
        self.text, self.content = text, content

    def raise_for_status(self):
        pass
