from __future__ import annotations

from dataclasses import dataclass
import json
import mimetypes
import os
from pathlib import Path
import re
import time
import urllib.parse
import urllib.request
from urllib.error import HTTPError
import uuid

from .models import CanvasStudent


class CanvasAPIError(RuntimeError):
    pass


@dataclass
class CanvasAPI:
    base_url: str
    token: str
    timeout_seconds: int = 60

    def list_course_students(self, course_id: int) -> list[CanvasStudent]:
        path = f"/api/v1/courses/{course_id}/users"
        query = {
            "enrollment_type[]": "student",
            "per_page": "100",
        }
        students: list[CanvasStudent] = []
        next_url: str | None = self._build_url(path, query)

        while next_url:
            payload, headers, _ = self._request_json("GET", next_url, absolute_url=True)
            for item in payload:
                students.append(
                    CanvasStudent(
                        user_id=int(item["id"]),
                        name=item.get("name") or item.get("sortable_name") or str(item["id"]),
                        sortable_name=item.get("sortable_name", "") or "",
                        short_name=item.get("short_name", "") or "",
                        sis_user_id=item.get("sis_user_id", "") or "",
                        login_id=item.get("login_id", "") or "",
                    )
                )
            next_url = self._next_link(headers.get("Link"))

        return students

    def get_assignment(self, course_id: int, assignment_id: int) -> dict:
        payload, _, _ = self._request_json(
            "GET",
            self._build_url(f"/api/v1/courses/{course_id}/assignments/{assignment_id}"),
        )
        return payload

    def update_assignment(self, course_id: int, assignment_id: int, fields: dict[str, str]) -> dict:
        payload, _, _ = self._request_json(
            "PUT",
            self._build_url(f"/api/v1/courses/{course_id}/assignments/{assignment_id}"),
            form=fields,
        )
        return payload

    def upload_submission_file(
        self,
        course_id: int,
        assignment_id: int,
        user_id: int,
        file_path: Path,
    ) -> dict:
        init_payload, _, _ = self._request_json(
            "POST",
            self._build_url(
                f"/api/v1/courses/{course_id}/assignments/{assignment_id}/submissions/{user_id}/files"
            ),
            form={
                "name": file_path.name,
                "size": str(file_path.stat().st_size),
                "content_type": mimetypes.guess_type(file_path.name)[0] or "application/pdf",
            },
        )

        upload_url = init_payload["upload_url"]
        upload_params = init_payload.get("upload_params", {})
        final_payload = self._multipart_upload(upload_url, upload_params, file_path)
        if "id" not in final_payload:
            raise CanvasAPIError(f"Upload finished without a file id for {file_path}.")
        return final_payload

    def upload_submission_comment_file(
        self,
        course_id: int,
        assignment_id: int,
        user_id: int,
        file_path: Path,
    ) -> dict:
        init_payload, _, _ = self._request_json(
            "POST",
            self._build_url(
                f"/api/v1/courses/{course_id}/assignments/{assignment_id}/submissions/{user_id}/comments/files"
            ),
            form={
                "name": file_path.name,
                "size": str(file_path.stat().st_size),
                "content_type": mimetypes.guess_type(file_path.name)[0] or "application/pdf",
            },
        )

        upload_url = init_payload["upload_url"]
        upload_params = init_payload.get("upload_params", {})
        final_payload = self._multipart_upload(upload_url, upload_params, file_path)
        if "id" not in final_payload:
            raise CanvasAPIError(f"Comment upload finished without a file id for {file_path}.")
        return final_payload

    def submit_file_on_behalf(
        self,
        course_id: int,
        assignment_id: int,
        user_id: int,
        file_id: int,
    ) -> dict:
        payload, _, _ = self._request_json(
            "POST",
            self._build_url(f"/api/v1/courses/{course_id}/assignments/{assignment_id}/submissions"),
            form={
                "submission[submission_type]": "online_upload",
                "submission[file_ids][]": str(file_id),
                "submission[user_id]": str(user_id),
            },
        )
        return payload

    def grade_or_comment_submission(
        self,
        course_id: int,
        assignment_id: int,
        user_id: int,
        posted_grade: str | None = None,
        comment_text: str | None = None,
        comment_file_ids: list[int] | None = None,
    ) -> dict:
        form: list[tuple[str, str]] = []
        if comment_text:
            form.append(("comment[text_comment]", comment_text))
        if comment_file_ids:
            for file_id in comment_file_ids:
                form.append(("comment[file_ids][]", str(file_id)))
        if posted_grade is not None:
            form.append(("submission[posted_grade]", posted_grade))
            form.append(("prefer_points_over_scheme", "true"))

        payload, _, _ = self._request_json(
            "PUT",
            self._build_url(
                f"/api/v1/courses/{course_id}/assignments/{assignment_id}/submissions/{user_id}"
            ),
            form_items=form,
        )
        return payload

    def grade_submission(
        self,
        course_id: int,
        assignment_id: int,
        user_id: int,
        posted_grade: str,
    ) -> dict:
        payload, _, _ = self._request_json(
            "PUT",
            self._build_url(
                f"/api/v1/courses/{course_id}/assignments/{assignment_id}/submissions/{user_id}"
            ),
            form={
                "submission[posted_grade]": posted_grade,
                "prefer_points_over_scheme": "true",
            },
        )
        return payload

    def update_assignment_grades(
        self,
        course_id: int,
        assignment_id: int,
        grade_map: dict[int, str],
    ) -> dict:
        form: dict[str, str] = {}
        for student_id, grade in grade_map.items():
            form[f"grade_data[{student_id}][posted_grade]"] = grade
        payload, _, _ = self._request_json(
            "POST",
            self._build_url(
                f"/api/v1/courses/{course_id}/assignments/{assignment_id}/submissions/update_grades"
            ),
            form=form,
        )
        return payload

    def get_progress(self, progress_id: int) -> dict:
        payload, _, _ = self._request_json(
            "GET",
            self._build_url(f"/api/v1/progress/{progress_id}"),
        )
        return payload

    def wait_for_progress(
        self,
        progress_id: int,
        poll_interval_seconds: float = 1.5,
        timeout_seconds: int = 300,
    ) -> dict:
        started = time.monotonic()
        while True:
            payload = self.get_progress(progress_id)
            state = payload.get("workflow_state")
            if state in {"completed", "failed"}:
                return payload
            if time.monotonic() - started > timeout_seconds:
                raise CanvasAPIError(f"Timed out waiting for Canvas progress job {progress_id}.")
            time.sleep(poll_interval_seconds)

    def _request_json(
        self,
        method: str,
        url: str,
        form: dict[str, str] | None = None,
        form_items: list[tuple[str, str]] | None = None,
        absolute_url: bool = False,
    ) -> tuple[dict | list, dict[str, str], str]:
        body = None
        headers = {"Authorization": f"Bearer {self.token}", "Accept": "application/json"}
        if form is not None and form_items is not None:
            raise ValueError("Use either form or form_items, not both.")
        if form is not None:
            body = urllib.parse.urlencode(form, doseq=True).encode("utf-8")
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        elif form_items is not None:
            body = urllib.parse.urlencode(form_items, doseq=True).encode("utf-8")
            headers["Content-Type"] = "application/x-www-form-urlencoded"

        request = urllib.request.Request(
            url if absolute_url else url,
            data=body,
            headers=headers,
            method=method,
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout_seconds) as response:
                response_body = response.read().decode("utf-8")
                payload = json.loads(response_body) if response_body else {}
                return payload, dict(response.headers), response.geturl()
        except HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            raise CanvasAPIError(f"{method} {url} failed with {error.code}: {detail}") from error

    def _multipart_upload(self, upload_url: str, upload_params: dict[str, str], file_path: Path) -> dict:
        boundary = f"----CanvasConnect{uuid.uuid4().hex}"
        body = bytearray()
        for key, value in upload_params.items():
            body.extend(f"--{boundary}\r\n".encode("utf-8"))
            body.extend(f'Content-Disposition: form-data; name="{key}"\r\n\r\n'.encode("utf-8"))
            body.extend(str(value).encode("utf-8"))
            body.extend(b"\r\n")

        body.extend(f"--{boundary}\r\n".encode("utf-8"))
        body.extend(
            (
                f'Content-Disposition: form-data; name="file"; filename="{file_path.name}"\r\n'
                f"Content-Type: {mimetypes.guess_type(file_path.name)[0] or 'application/pdf'}\r\n\r\n"
            ).encode("utf-8")
        )
        body.extend(file_path.read_bytes())
        body.extend(b"\r\n")
        body.extend(f"--{boundary}--\r\n".encode("utf-8"))

        request = urllib.request.Request(
            upload_url,
            data=bytes(body),
            headers={
                "Content-Type": f"multipart/form-data; boundary={boundary}",
                "Accept": "application/json",
            },
            method="POST",
        )

        opener = urllib.request.build_opener(_NoRedirectHandler)
        try:
            with opener.open(request, timeout=self.timeout_seconds) as response:
                content = response.read().decode("utf-8")
                return json.loads(content) if content else {}
        except HTTPError as error:
            if error.code in {301, 302, 303}:
                location = error.headers.get("Location")
                if not location:
                    raise CanvasAPIError("Canvas upload redirected without a Location header.") from error
                follow = urllib.request.Request(location, headers={"Accept": "application/json"}, method="GET")
                with urllib.request.urlopen(follow, timeout=self.timeout_seconds) as response:
                    content = response.read().decode("utf-8")
                    return json.loads(content) if content else {}
            detail = error.read().decode("utf-8", errors="replace")
            raise CanvasAPIError(f"Upload failed with {error.code}: {detail}") from error

    def _build_url(self, path: str, query: dict[str, str] | None = None) -> str:
        base = self.base_url.rstrip("/")
        url = f"{base}{path}"
        if query:
            url += "?" + urllib.parse.urlencode(query, doseq=True)
        return url

    @staticmethod
    def _next_link(link_header: str | None) -> str | None:
        if not link_header:
            return None
        for part in link_header.split(","):
            match = re.search(r'<([^>]+)>;\s*rel="([^"]+)"', part)
            if match and match.group(2) == "next":
                return match.group(1)
        return None


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def token_from_env(token_env_var: str) -> str:
    token = os.environ.get(token_env_var, "").strip()
    if not token:
        raise CanvasAPIError(
            f"Canvas API token was not found in environment variable {token_env_var}."
        )
    return token
