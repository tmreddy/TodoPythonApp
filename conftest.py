# Makes the repository root importable, so the test modules can `from app import
# main`.
#
# Without this file, `pytest` fails at collection with
# "ModuleNotFoundError: No module named 'app'". The reason is pytest's default
# import mode: for each test module it walks up until it finds a directory with no
# __init__.py, and inserts THAT directory into sys.path. test/ is not a package,
# so pytest inserts test/ -- and the repository root, where app/ lives, never
# makes it onto the path.
#
# `python -m pytest` appears to work only because the `-m` flag adds the current
# directory to sys.path itself. That hides the problem locally and exposes it in
# CI, which invokes `pytest` directly.
#
# A conftest.py at the root fixes it for every invocation: pytest adds a
# conftest's own directory to sys.path before importing anything. The file needs
# no contents to do that.
