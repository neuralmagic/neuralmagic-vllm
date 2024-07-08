# this script parses the provided coverage JSON file to report
# the results broken down into categories of interest.
import argparse
from collections import UserDict
from pathlib import Path
from typing import Optional

import pandas as pd


class CoverageMetrics(UserDict):
    """
    encapsulates code coverage metrics
    """
    def __init__(self, user_dict):
        super().__init__(user_dict)
        if "percent_covered_display" in self.data:
            del self.data["percent_covered_display"]


class CodeCoverage:
    """
    reads and reports on code coverage data as generated by the coverage tool
    """
    def __init__(self, file_path: Path):
        self.format: [int, None] = None
        self.version: [str, None] = None
        self.timestamp: [str, None] = None
        self.show_contexts: [bool, None] = None
        self.branch_coverage: [bool, None] = None
        self.overall_metrics: [CoverageMetrics, None] = None
        self.tests: [pd.Series, None] = None
        self.source: [pd.Series, None] = None

        if file_path.suffix == ".json":
            if not file_path.exists():
                raise ValueError(f"{file_path} not found")
            self._from_json(file_path)
        else:
            raise ValueError("only coverage json reports are supported")

    def _from_json(self, json_file_path: Path):
        """
        loads the code coverage data from a JSON report generated with
        `coverage json`
        :param json_file_path: path to the file to load
        """
        coverage_df = pd.read_json(json_file_path, orient="records")
        self.format = coverage_df["meta"]["format"]
        self.version = coverage_df["meta"]["version"]
        self.timestamp = coverage_df["meta"]["timestamp"]
        self.show_contexts = coverage_df["meta"]["show_contexts"]
        self.branch_coverage = coverage_df["meta"]["branch_coverage"]
        self.overall_metrics = CoverageMetrics(coverage_df["totals"].dropna().to_dict())

        # segment the list of files by test cases and source code
        files_df = coverage_df.loc[:, ['files']].dropna()
        self.tests = files_df.iloc[files_df.index.str.startswith("tests/")]
        self.source = files_df[~files_df.index.isin(self.tests.index)]

        # add a column to the list of source files to facilitate grouping
        # metrics by top level directories under vllm
        def get_sub_dir(file_path):
            file_parts = Path(file_path).parts
            subdir = file_parts[file_parts.index("vllm") + 1]
            if subdir == Path(file_path).name:
                # we're at the root of the vllm dir, so leave subdir empty
                subdir = ""
            return subdir

        # temporarily move the index to a "filepath" column
        self.source.reset_index(names="filepath", inplace=True)
        # extract the subdirectory under vllm from filepath to the sub_dir column
        self.source.loc[:, "sub_dir"] = self.source.loc[:, "filepath"].apply(get_sub_dir)
        # make the filepath column the index again
        self.source.set_index("filepath", inplace=True)

    @staticmethod
    def _calculate_metrics(coverage_data: pd.Series) -> CoverageMetrics:
        """
        common method to calculate metrics
        """
        metrics_dict = {}
        for metric in ["covered_lines", "num_statements", "missing_lines", "excluded_lines"]:
            metrics_dict[metric] = sum(d[0]["summary"][metric] for d in coverage_data)
        metrics_dict["percent_covered"] = metrics_dict["covered_lines"] / metrics_dict["num_statements"] * 100
        return CoverageMetrics(metrics_dict)

    def tests_metrics(self) -> CoverageMetrics:
        """
        creates summary metrics for all tests
        """
        return self._calculate_metrics(self.tests.values)

    def source_metrics(self, sub_dir: Optional[str] = None) -> CoverageMetrics:
        """
        creates summary metrics for the requested vllm subdirectory,
        or for the reported vllm source if a subdirectory is not specified.
        sub_dir = "" will report for files directly under vllm
        """
        data = self.source
        if sub_dir is not None:
            data = self.source[self.source["sub_dir"] == sub_dir]

        return self._calculate_metrics(data.values)

    def to_github_markdown(self) -> str:
        """
        returns a string in the form of github compatible markdown with top
        level and drill down metrics.
        """
        # make a dataframe with top level metric summary info
        overall_metrics = self.overall_metrics
        overall_metrics["Collection"] = "Overall"
        test_metrics = self.tests_metrics()
        test_metrics["Collection"] = "Test Code"
        source_metrics = self.source_metrics()
        source_metrics["Collection"] = "Source Code"
        summary_df = pd.DataFrame(
            [overall_metrics, test_metrics, source_metrics]
        )
        # make the percent_covered value compatible with the string "%" formatting
        summary_df["percent_covered"] = summary_df["percent_covered"] / 100

        # compose a set of the subdirectory breakdown summary info
        breakdown_list = []
        for sub_dir in sorted(cc.source["sub_dir"].unique()):
            sub_dir_metrics = cc.source_metrics(sub_dir)
            if sub_dir == "":
                label = "vllm 'root'"
            else:
                label = sub_dir
            sub_dir_metrics["Collection"] = label
            breakdown_list.append(sub_dir_metrics)
        breakdown_df = pd.DataFrame(breakdown_list)
        # make the percent_covered value compatible with the string "%" formatting
        breakdown_df["percent_covered"] = breakdown_df["percent_covered"] / 100

        # join the top level and breakdown data with separator rows between them
        # add a separator row and subtitle row
        empty_row_df = pd.Series(pd.NA, index=summary_df.columns).to_frame().transpose()
        header_row_df = empty_row_df.copy()
        header_row_df["Collection"] = "vllm Subdirs"
        summary_df = pd.concat([summary_df, empty_row_df, header_row_df, breakdown_df], ignore_index=True)
        # clean up the `nan` values for display purposes
        summary_df = summary_df.astype(str)
        summary_df.replace({"nan": None}, inplace=True)

        return summary_df.to_markdown(index=False, tablefmt="github", missingval="", floatfmt=(".0f", ".0f", ".0f", ".0f", ".0f", ".1%"), colalign=("left", "right", "right", "right", "right", "decimal"))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("coverage_json_file", type=str, help="file path to coverage JSON output")
    args = parser.parse_args()
    cc = CodeCoverage(Path(args.coverage_json_file))

    print(cc.to_github_markdown())
