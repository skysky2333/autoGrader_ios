from __future__ import annotations

from pathlib import Path
import shutil


class PDFError(RuntimeError):
    pass


def build_submission_pdf(scan_paths: list[Path], output_path: Path) -> None:
    if not scan_paths:
        raise PDFError("No scan files were found for this submission.")

    if len(scan_paths) == 1 and scan_paths[0].suffix.lower() == ".pdf":
        shutil.copyfile(scan_paths[0], output_path)
        return

    suffixes = {path.suffix.lower() for path in scan_paths}
    if not suffixes.issubset({".jpg", ".jpeg"}):
        unsupported = ", ".join(sorted(suffixes))
        raise PDFError(
            "Only JPG/JPEG scan exports are supported for PDF assembly right now. "
            f"Unsupported file types: {unsupported}"
        )

    image_infos = [jpeg_info(path) for path in scan_paths]
    pdf_bytes = _build_pdf_bytes(scan_paths, image_infos)
    output_path.write_bytes(pdf_bytes)


def jpeg_info(path: Path) -> tuple[int, int, str]:
    data = path.read_bytes()
    if len(data) < 4 or data[0:2] != b"\xff\xd8":
        raise PDFError(f"{path} is not a valid JPEG file.")

    index = 2
    while index + 9 < len(data):
        while index < len(data) and data[index] == 0xFF:
            index += 1
        if index >= len(data):
            break
        marker = data[index]
        index += 1

        if marker in {0xD8, 0xD9}:
            continue

        if index + 2 > len(data):
            break
        segment_length = int.from_bytes(data[index:index + 2], "big")
        if segment_length < 2:
            raise PDFError(f"{path} contains an invalid JPEG segment.")

        if marker in {
            0xC0,
            0xC1,
            0xC2,
            0xC3,
            0xC5,
            0xC6,
            0xC7,
            0xC9,
            0xCA,
            0xCB,
            0xCD,
            0xCE,
            0xCF,
        }:
            if index + 7 > len(data):
                break
            precision = data[index + 2]
            height = int.from_bytes(data[index + 3:index + 5], "big")
            width = int.from_bytes(data[index + 5:index + 7], "big")
            components = data[index + 7]
            if precision != 8:
                raise PDFError(f"{path} uses unsupported JPEG precision {precision}.")
            colorspace = {1: "/DeviceGray", 3: "/DeviceRGB", 4: "/DeviceCMYK"}.get(components)
            if colorspace is None:
                raise PDFError(f"{path} uses unsupported JPEG component count {components}.")
            return width, height, colorspace

        index += segment_length

    raise PDFError(f"Could not determine JPEG dimensions for {path}.")


def _build_pdf_bytes(scan_paths: list[Path], image_infos: list[tuple[int, int, str]]) -> bytes:
    objects: list[bytes] = [b"", b""]
    page_ids: list[int] = []

    for page_index, (scan_path, image_info) in enumerate(zip(scan_paths, image_infos), start=1):
        width, height, colorspace = image_info
        image_bytes = scan_path.read_bytes()

        image_dict = [
            "<<",
            "/Type /XObject",
            "/Subtype /Image",
            f"/Width {width}",
            f"/Height {height}",
            f"/ColorSpace {colorspace}",
            "/BitsPerComponent 8",
            "/Filter /DCTDecode",
            f"/Length {len(image_bytes)}",
            ">>",
        ]
        image_object = _stream_object("\n".join(image_dict).encode("ascii"), image_bytes)
        image_object_id = len(objects) + 1
        objects.append(image_object)

        content_stream = (
            f"q\n{width} 0 0 {height} 0 0 cm\n/Im{page_index} Do\nQ\n".encode("ascii")
        )
        content_object = _stream_object(
            f"<< /Length {len(content_stream)} >>".encode("ascii"),
            content_stream,
        )
        content_object_id = len(objects) + 1
        objects.append(content_object)

        page_object = (
            "<<\n"
            "/Type /Page\n"
            "/Parent 2 0 R\n"
            f"/MediaBox [0 0 {width} {height}]\n"
            f"/Contents {content_object_id} 0 R\n"
            f"/Resources << /ProcSet [/PDF /ImageC] /XObject << /Im{page_index} {image_object_id} 0 R >> >>\n"
            ">>"
        ).encode("ascii")
        page_object_id = len(objects) + 1
        objects.append(page_object)
        page_ids.append(page_object_id)

    pages_object = (
        "<<\n"
        "/Type /Pages\n"
        f"/Count {len(page_ids)}\n"
        f"/Kids [{' '.join(f'{page_id} 0 R' for page_id in page_ids)}]\n"
        ">>"
    ).encode("ascii")
    catalog_object = b"<< /Type /Catalog /Pages 2 0 R >>"

    objects[0] = catalog_object
    objects[1] = pages_object

    output = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = [0]

    for object_id, object_bytes in enumerate(objects, start=1):
        offsets.append(len(output))
        output.extend(f"{object_id} 0 obj\n".encode("ascii"))
        output.extend(object_bytes)
        output.extend(b"\nendobj\n")

    xref_offset = len(output)
    output.extend(f"xref\n0 {len(objects) + 1}\n".encode("ascii"))
    output.extend(b"0000000000 65535 f \n")
    for offset in offsets[1:]:
        output.extend(f"{offset:010d} 00000 n \n".encode("ascii"))

    output.extend(
        (
            "trailer\n"
            f"<< /Size {len(objects) + 1} /Root 1 0 R >>\n"
            "startxref\n"
            f"{xref_offset}\n"
            "%%EOF\n"
        ).encode("ascii")
    )
    return bytes(output)


def _stream_object(header: bytes, stream: bytes) -> bytes:
    return header + b"\nstream\n" + stream + b"\nendstream"
