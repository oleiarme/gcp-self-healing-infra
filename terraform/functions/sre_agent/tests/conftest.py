"""Shared test configuration for sre_agent tests.

Sets required environment variables before any module imports.
"""

import os

# Set required env vars for Settings instantiation during tests
os.environ.setdefault("GCP_PROJECT_ID", "test-project-id")
