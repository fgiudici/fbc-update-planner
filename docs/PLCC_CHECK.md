# PLCC and catalog assessment

## Entry point

```go
assessment, err := plcccheck.Assess(source, inventory, plcc.DatasetOptions{
    Packages:   packages,
    Validators: []string{"syntax", "catalog"},
})
```

- `source` is one PLCC snapshot, already fetched or loaded by the caller.
- `inventory` is already parsed or rendered using `pkg/catalog`. Nil skips
  catalog checks; a non-nil empty inventory represents an empty catalog.
- `Packages` follows Dataset semantics: nil selects all packages; a non-nil
  empty slice selects none. Explicit names are deduplicated in request order.
  All-package reports use alphabetical order and include the union of PLCC,
  catalog bundle, and catalog lifecycle packages. Unnamed PLCC context products
  remain available to validators without becoming report rows.
- `Validators` follows Dataset semantics: empty means `all`, and `none` disables
  PLCC checks. Mandatory FBC converters and default filters always apply to
  products that pass the selected PLCC checks.

The function performs no I/O and leaves inputs unchanged. Its result is ordinary,
caller-owned data. Errors in options or assessed catalog version syntax return
nil, never a partial report. Missing PLCC and rejected products are assessment
results, not execution errors.

`Assessment.CatalogChecked` distinguishes unchecked and empty catalogs even when
there are no selected packages. `FilteredPLCC` and `FBC` retain pipeline outputs
from the same validation/translation pass for artifact generation, without another
fetch or conversion. They are independent of the caller's source and omitted from
assessment JSON. `FilteredPLCC` excludes PLCC validation failures; `FBC` also
excludes conversion/filter failures. Disabling duplicate validation can retain
multiple translated products for a package; the assessment does not collapse them.

## Evidence and identity

Each package assessment includes source product indices, unique raw source
version names, successfully produced lifecycle versions, structured failures,
optional catalog coverage, typed issues, and one operator-level action.

Source indices refer to the supplied PLCC snapshot. Every matching product
contributes evidence; duplicate package names never discard later products.
Comma-separated aliases follow Dataset selection and validation semantics. A
failure can target one alias while rejecting the entire source product. The
failure retains its actual target, and every affected alias retains the failure.
Only the target of `REQ-VAL-01` receives the `DUPLICATE` PLCC status; another alias
blocked by that product's rejection receives `INVALID`.

PLCC failures retain validator label, group, scope, targets, and original reasons.
FBC failures retain their source index and original reasons, including converter
and filter labels. The assessment does not extract metadata from reason strings.
Translation follows the existing pipeline: rejected PLCC products are skipped,
and converter/filter failures reject the whole translated product. No attempt is
made to translate isolated versions from a rejected product.

## Version comparison and coverage

Bundle versions accept canonical semantic versions and plain `MAJOR.MINOR`
shorthand for compatibility with the former reporting script. Patch, prerelease,
and build components collapse to one distinct `MAJOR.MINOR`. Original bundle
names and versions remain in the coverage evidence. Invalid version strings,
leading zeros in numeric core/prerelease components, and major/minor values
outside the FBC type's range are errors with package/bundle context.

Catalog lifecycle version names must parse as FBC `MAJOR.MINOR`. PLCC source
names are retained verbatim and matched exactly to the required `MAJOR.MINOR`:
a malformed source name such as `1.2.3` does not establish the presence of `1.2`.
The malformed source remains visible in failures and raw version evidence.
Catalog syntax checks apply to the assessed package selection.

Normalized version lists are numerically sorted and deduplicated.
Coverage counts distinct bundle `MAJOR.MINOR` values present in lifecycle data:

- `NO BUNDLES`: zero bundles, regardless of lifecycle entry presence.
- `MISSING`: bundles exist but there is no lifecycle entry.
- `OK`: bundles exist and every required version is present in lifecycle data.
- `X/Y`: an entry exists but only X of Y required versions are present.

These statuses apply in the order listed. An empty lifecycle entry with bundles
produces `0/Y`. Coverage evaluates version presence only; it does not inspect
shipped phases or compatibility data. PLCC versions without bundles do not imply
missing bundles: only zero bundles produces `NO BUNDLES`.

## Completeness and regression findings

`PackageAssessment.Issues` replaces the former action-bearing `Gaps`. Each `Issue`
contains a typed `Kind` and an optional `Version` (`MAJOR.MINOR`). Package-level
issues have no version. Version findings have no action of their own.

| Issue kind | Evidence |
| --- | --- |
| `plcc-package-missing` | Package absent from all source PLCC products |
| `plcc-version-missing` | Bundle requires a version absent from both source PLCC and catalog lifecycle data |
| `plcc-version-regressed` | Shipped lifecycle version absent from source PLCC |
| `catalog-bundles-missing` | Operator has zero bundles |
| `catalog-lifecycle-missing` | No lifecycle entry exists for the operator |
| `catalog-lifecycle-version-missing` | Required bundle MAJOR.MINOR absent from catalog lifecycle data |

PLCC completeness checks **all bundle versions**, including those already covered
by lifecycle data. Regression checks **all shipped lifecycle versions**, including
versions without corresponding bundles and packages with no bundles. A regression
describes the discrepancy between current PLCC and shipped lifecycle data; it
does not establish when or why the data disappeared.

A version absent from PLCC but present in shipped lifecycle data gets a regression
issue instead of an ordinary missing-PLCC-version issue. Whole-package absence
also retains every version finding. Missing lifecycle entries retain both the
entry-level issue and each uncovered bundle version, so no affected version is
lost. The absence of bundles and lifecycle data produces both package-level issues.

Issues are deterministic: package-level issues first (PLCC package, bundles,
lifecycle entry), then version issues in numeric order, PLCC before catalog for
the same version. Each distinct affected MAJOR.MINOR is reported once per kind.
Validation/conversion failures remain in `Failures`, retaining all original
reasons and metadata independently of these issues.

## PLCC status and operator action

Each operator receives exactly one PLCC status, with this precedence:

| Status | Condition |
| --- | --- |
| `MISSING` | Package absent from source PLCC |
| `DUPLICATE` | Selected duplicate-package validation rejected this package |
| `INVALID` | PLCC validation or mandatory FBC conversion/filtering rejected a product |
| `REGRESSED` | Any shipped lifecycle version is absent from current PLCC |
| `INCOMPLETE` | Existing package lacks any required bundle MAJOR.MINOR version |
| `OK` | None of the above |

An existing product can be `INCOMPLETE` even if all required versions are absent.
`Action` is used only for the operator-level recommendation:

1. **PLCC add** when the package is absent from PLCC.
2. **PLCC fix** for `DUPLICATE`, `INVALID`, `REGRESSED`, or `INCOMPLETE` PLCC.
3. **OPERATOR add** when PLCC is `OK` and the checked catalog has no bundles,
   even if it contains lifecycle data for the package.
4. **OPERATOR build** when PLCC is `OK`, bundles exist, and catalog lifecycle
   data is missing or incomplete.
5. **OK** when all applicable checks pass.

An explicit reporting exception overrides this recommendation with **SKIPPED**,
without changing PLCC or catalog status.

Any product rejection blocks a build recommendation, even if another product
for that package translated successfully with duplicate validation disabled.
Produced version evidence and all catalog issues are retained for investigation.

Without a catalog, no completeness or regression checks are possible. Catalog
evidence is nil, and issues can only report an absent PLCC package. Validation
and mandatory translation still run. Successful assessment receives action `OK`,
which renderers must qualify as **PLCC OK; catalog not checked**. It does not
count as fully ready in both PLCC and catalog.
