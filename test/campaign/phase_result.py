#!/usr/bin/env python3
"""Checked execution result shared by every campaign phase.

Each phase entry point returns a PhaseResult for that call alone. Its status
says whether the phase ran to the end; its findings are Varnish defects; its
diagnostics are execution errors. Findings and execution errors are never mixed.

  completed   the phase ran to the end; findings are the whole result
  incomplete  the phase ran but could not measure what it set out to (reasons)
  error       the phase raised; findings are those collected before the error
  not-run     the campaign stopped before reaching the phase
"""

import contextlib
import traceback

COMPLETED = "completed"
INCOMPLETE = "incomplete"
ERROR = "error"
NOT_RUN = "not-run"


def _finding_dict(finding):
    return finding.to_dict() if hasattr(finding, "to_dict") else dict(finding)


def exception_diagnostic(exc):
    return {
        "error": f"{type(exc).__name__}: {exc}",
        "traceback": "".join(traceback.format_exception(type(exc), exc, exc.__traceback__)),
    }


class FindingLog:
    """Findings collected by one phase call."""

    def __init__(self):
        self.entries = []

    def __len__(self):
        return len(self.entries)

    def append(self, finding):
        self.entries.append(_finding_dict(finding))

    @contextlib.contextmanager
    def observe(self, **evidence):
        """Record an observation's evidence before its narrative is formatted.

        Yields `record(finding)`, which fills in the entry. If formatting the
        narrative raises, the evidence stays in the log with the error and the
        exception propagates to fail the phase.
        """
        entry = {"evidence": evidence}
        self.entries.append(entry)
        try:
            yield lambda finding: entry.update(_finding_dict(finding))
        except Exception as exc:
            entry["narrative_error"] = f"{type(exc).__name__}: {exc}"
            raise

    def to_list(self):
        return [dict(entry) for entry in self.entries]


class PhaseResult:
    def __init__(self, status, findings=(), diagnostics=(), reasons=()):
        self._status = status
        self.findings = list(findings)
        self.diagnostics = list(diagnostics)
        self.reasons = list(reasons)

    @property
    def status(self):
        return self._status

    @classmethod
    def not_run(cls):
        return cls(NOT_RUN)

    @classmethod
    def from_exception(cls, exc, findings=()):
        return cls(ERROR, findings, [exception_diagnostic(exc)])

    def to_dict(self):
        return {
            "status": self.status,
            "reasons": self.reasons,
            "findings": self.findings,
            "diagnostics": self.diagnostics,
        }


def run_phase(body):
    """Run body(findings) with a fresh FindingLog and return its PhaseResult."""
    findings = FindingLog()
    try:
        body(findings)
    except Exception as exc:
        return PhaseResult.from_exception(exc, findings.to_list())
    return PhaseResult(COMPLETED, findings.to_list())
