def serialize_doc(doc: dict) -> dict:
    """Converts a MongoDB document's _id into a plain string id for API responses."""
    out = dict(doc)
    out["id"] = str(out.pop("_id"))
    return out
