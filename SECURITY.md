# Security Policy

## Supported versions

Only the latest version on the `main` branch receives security fixes.

## Reporting a vulnerability

**Please do not report security vulnerabilities through public GitHub issues, discussions, or pull
requests.**

Report them privately instead, by either:

- [GitHub private vulnerability reporting](https://github.com/accentient/ado-assessment/security/advisories/new)
  (preferred), or
- email to <richard@accentient.com>

Please include:

- A description of the issue and its impact
- Steps to reproduce, or a proof of concept
- The affected file, function, or version, if known

Do not include a real token or an unscrubbed report in your message.

You will receive a reply acknowledging the report. Once the issue is confirmed, a fix will be
prepared and released, and you will be credited in the advisory unless you prefer otherwise.

## Scope

Because this tool handles a privileged token and produces personnel data, the following are
treated as security issues:

- Any code path that could **modify** an Azure DevOps organization. The tool is meant to be
  read-only.
- A token being written to a report, console output, or any other file.
- Report content being written outside `reports/` by default, or anywhere it could be committed.
- Anything that sends organization data to a destination other than the organization itself.

## Safe use

- Use a PAT with **read scopes only**, and give it a short expiry.
- Keep the token in Windows Credential Manager, never in the script or source control.
- Treat reports as personnel data. See *Handle the output with care* in the [README](README.md).
