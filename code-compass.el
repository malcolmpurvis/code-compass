;;; code-compass.el --- Make Emacs your compass in a sea of software complexity.

;; Copyright (C) 2020 Andrea Giugliano

;; Author: Andrea Giugliano <agiugliano@live.it>
;; Version: 0.0.3
;; Package-Version: 20210101
;; Keywords: emacs, sofware, analysis

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Make Emacs your compass in a sea of software complexity
;;
;; This tool puts the power and knowledge of your repository history in your hands.
;; The current analyses supported are:
;;   - c/show-hotspots:
;;     show hotspots in code repository as a circle diagram.
;;     Circles are packages or modules.
;;     The redder the circle, the more it has been modified lately. The bigger the more code it contains.
;;
;; See documentation on https://github.com/ag91/code-compass

;;; Code:
(require 'f)
(require 's)
(require 'simple-httpd)
(require 'async)


(defgroup code-compass nil
  "Options specific to code-compass."
  :tag "code-compass"
  :group 'code-compass)

(defcustom c/default-periods
  '("beginning" "1d" "2d" "3d" "6d" "12d" "18d" "24d" "1m" "2m" "6m")
  "A list of choices for starting date for reducing the Git log for analysis. 'beginning' is a keyword to say to not reduce.'Nd' means to start after N days, where N is a positive number. 'Nm' means to start after N months, where N is a positive number."
  :group 'code-compass)

(defcustom c/snapshot-periods
  '("1d" "3m" "6m" "9m" "12m" "15m")
  "A list of snapshots periods to show evolution of analyses over time."
  :group 'code-compass)

(defcustom c/code-maat-command
  "docker run -v /tmp/:/data code-maat-app"
  "Command to run Code-maat (https://github.com/adamtornhill/code-maat). Currently defaults to use docker because easier to setup."
  :group 'code-compass)

(defcustom c/preferred-browser
  "chromium"
  "Browser to use to open graphs served by webserver."
  :group 'code-compass)

(defun c/subtract-to-now (n month|day &optional time)
  "Subtract N * MONTH|DAY to current time. Optionally give TIME from which to start."
  (time-subtract
   (or time (current-time))
   (seconds-to-time (* 60 60 month|day n))))

(defun c/request-date (days|months &optional time)
  "Request date in days or months by asking how many DAYS|MONTHS ago. Optionally give TIME from which to start."
  (interactive
   (list (completing-read "From how long ago?" c/default-periods)))
  (when (not (string= days|months "beginning"))
    (format-time-string
     "%Y-%m-%d"
     (apply
      'c/subtract-to-now
      (-concat
       (if (s-contains-p "m" days|months)
           (list (string-to-number (s-replace "m" "" days|months)) (* 24 31))
         (list (string-to-number (s-replace "d" "" days|months)) 24))
       (list time))))))

(defun c/first (l)
  (car l))

(defun c/second (l)
  (nth 1 l))

(defun c/third (l)
  (nth 2 l))

(defun c/produce-git-report (repository date &optional before-date)
  "Create git report for REPOSITORY with a Git log starting at DATE. Define optionally a BEFORE-DATE."
  (interactive
   (list (call-interactively 'c/request-date)))
  (message "Producing git report...")
  (shell-command
   (s-concat
    (format "cd %s;" repository)
    "git log --all --numstat --date=short --pretty=format:'--%h--%ad--%aN' --no-renames "
    (if date
        (format
         "--after=%s "
         date)
      "")
    (if before-date
        (format
         "--before=%s "
         before-date)
      "")
    (format
     "> /tmp/%s.log"
     (f-filename repository))))
  repository)

(defun c/run-code-maat (command repository)
  "Run code-maat's COMMAND on REPOSITORY."
  (message "Producing code-maat %s report for %s..." command repository)
  (shell-command
   (format
    "%s -l /data/%s.log -c git2 -a %s > /tmp/%s-%s.csv"
    c/code-maat-command
    (f-filename repository)
    command
    (f-filename repository)
    command)))

(defun c/produce-code-maat-revisions-report (repository)
  "Create code-maat revisions report for REPOSITORY."
  (c/run-code-maat "revisions" repository)
  repository)

(defun c/produce-cloc-report (repository)
  "Create cloc report for REPOSITORY."
  (message "Producing cloc report...")
  (shell-command
   (format "cd %s; cloc ./ --by-file --csv --quiet --report-file=/tmp/cloc-%s.csv" repository (f-filename repository)))
  repository)

(defun c/generate-merger-script (repository)
  "Generate a Python script to give weights to the circle diagram of REPOSITORY."
  (with-temp-file "/tmp/csv_as_enclosure_json.py"
    (insert
     "
#!/bin/env python

#######################################################################
## This program generates a JSON document suitable for a D3.js
## enclosure diagram visualization.
## The input data is read from two CSV files:
##  1) The complete system structure, including size metrics.
##  2) A hotspot analysis result used to assign weights to the modules.
#######################################################################

import argparse
import csv
import json
import sys

class MergeError(Exception):
        def __init__(self, message):
                Exception.__init__(self, message)

class Merged(object):
        def __init__(self):
                self._all_modules_with_complexity = {}
                self._merged = {}

        def sorted_result(self):
                # Sort on descending order:
                ordered = sorted(self._merged.items(), key=lambda item: item[1][0], reverse=True)
                return ordered

        def extend_with(self, name, freqs):
                if name in self._all_modules_with_complexity:
                        complexity = self._all_modules_with_complexity[name]
                        self._merged[name] = freqs, complexity

        def record_detected(self, name, complexity):
                self._all_modules_with_complexity[name] = complexity

def write_csv(stats):
        print 'module,revisions,code'
        for s in stats:
                name, (f,c) = s
                print name + ',' + f + ',' + c

def parse_complexity(merged, row):
        name = row[1][2:]
        complexity = row[4]
        merged.record_detected(name, complexity)

def parse_freqs(merged, row):
        name = row[0]
        freqs = row[1]
        merged.extend_with(name, freqs)

def merge(revs_file, comp_file):
        merged = Merged()
        parse_csv(merged, comp_file, parse_complexity, expected_format='language,filename,blank,comment,code')
        parse_csv(merged, revs_file, parse_freqs, expected_format='entity,n-revs')
        write_csv(merged.sorted_result())

######################################################################
## Parse input
######################################################################

def validate_content_by(heading, expected):
        if not expected:
                return # no validation
        comparison = expected.split(',')
        stripped = heading[0:len(comparison)] # allow extra fields
        if stripped != comparison:
                raise MergeError('Erroneous content. Expected = ' + expected + ', got = ' + ','.join(heading))

def parse_csv(filename, parse_action, expected_format=None):
        def read_heading_from(r):
                p = r.next()
                while p == []:
                        p = r.next()
                return p
        with open(filename, 'rb') as csvfile:
                r = csv.reader(csvfile, delimiter=',')
                heading = read_heading_from(r)
                validate_content_by(heading, expected_format)
                return [parse_action(row) for row in r]

class StructuralElement(object):
        def __init__(self, name, complexity):
                self.name = name
                self.complexity = complexity
        def parts(self):
                return self.name.split('/')

def parse_structural_element(csv_row):
        name = csv_row[1][2:]
        complexity = csv_row[4]
        return StructuralElement(name, complexity)

def make_element_weight_parser(weight_column):
        \"\"\" Parameterize with the column - this allows us
                to generate data from different analysis result types.
        \"\"\"
        def parse_element_weight(csv_row):
                name = csv_row[0]
                weight = float(csv_row[weight_column]) # Assert not zero?
                return name, weight
        return parse_element_weight

######################################################################
## Calculating weights from the given CSV analysis file
######################################################################

def module_weight_calculator_from(analysis_results):
        max_raw_weight = max(analysis_results, key=lambda e: e[1])
        max_value = max_raw_weight[1]
        normalized_weights = dict([(name, (1.0 / max_value) * n) for name,n in analysis_results])
        def normalized_weight_for(module_name):
                if module_name in normalized_weights:
                        return normalized_weights[module_name]
                return 0.0
        return normalized_weight_for

######################################################################
## Building the structure of the system
######################################################################

def _matching_part_in(hierarchy, part):
        return next((x for x in hierarchy if x['name']==part), None)

def _ensure_branch_exists(hierarchy, branch):
        existing = _matching_part_in(hierarchy, branch)
        if not existing:
                new_branch = {'name':branch, 'children':[]}
                hierarchy.append(new_branch)
                existing = new_branch
        return existing

def _add_leaf(hierarchy, module, weight_calculator, name):
        # TODO: augment with weight here!
        new_leaf = {'name':name, 'children':[],
                    'size':module.complexity,
                    'weight':weight_calculator(module.name)}
        hierarchy.append(new_leaf)
        return hierarchy

def _insert_parts_into(hierarchy, module, weight_calculator, parts):
        \"\"\" Recursively traverse the hierarchy and insert the individual parts
                of the module, one by one.
                The parts specify branches. If any branch is missing, it's
                created during the traversal.
                The final part specifies a module name (sans its path, of course).
                This is where we add size and weight to the leaf.
        \"\"\"
        if len(parts) == 1:
                return _add_leaf(hierarchy, module, weight_calculator, name=parts[0])
        next_branch = parts[0]
        existing_branch = _ensure_branch_exists(hierarchy, next_branch)
        return _insert_parts_into(existing_branch['children'],
                                                          module,
                                                          weight_calculator,
                                                          parts=parts[1:])

def generate_structure_from(modules, weight_calculator):
        hierarchy = []
        for module in modules:
                parts = module.parts()
                _insert_parts_into(hierarchy, module, weight_calculator, parts)

        structure = {'name':'root', 'children':hierarchy}
        return structure

######################################################################
## Output
######################################################################

def write_json(result):
        print json.dumps(result)

######################################################################
## Main
######################################################################

# TODO: turn it around: parse the weights first and add them to individual elements
# as the raw structure list is built!

def run(args):
        raw_weights = parse_csv(args.weights, parse_action=make_element_weight_parser(args.weightcolumn))
        weight_calculator = module_weight_calculator_from(raw_weights)

        structure_input = parse_csv(args.structure,
                                                                expected_format='language,filename,blank,comment,code',
                                                                parse_action=parse_structural_element)
        weighted_system_structure = generate_structure_from(structure_input, weight_calculator)
        write_json(weighted_system_structure)

if __name__ == \"__main__\":
        parser = argparse.ArgumentParser(description='Generates a JSON document suitable for enclosure diagrams.')
        parser.add_argument('--structure', required=True, help='A CSV file generated by cloc')
        parser.add_argument('--weights', required=True, help='A CSV file with hotspot results from Code Maat')
        parser.add_argument('--weightcolumn', type=int, default=1, help=\"The index specifying the columnt to use in the weight table\")
        # TODO: add arguments to specify which CSV columns to use!

        args = parser.parse_args()
        run(args)

"
     ))
  repository)


(defun c/generate-d3-lib (repository)
  "Make available the D3 library for REPOSITORY. This is just to not depend on a network connection."
  (mkdir (format "/tmp/%s/d3/" (f-filename repository)) t)
  (with-temp-file (format "/tmp/%s/d3/d3.min.js" (f-filename repository))
    (insert (base64-decode-string
             "IWZ1bmN0aW9uKCl7ZnVuY3Rpb24gbihuLHQpe3JldHVybiB0Pm4/LTE6bj50PzE6bj49dD8wOjAv
MH1mdW5jdGlvbiB0KG4pe3JldHVybiBudWxsIT1uJiYhaXNOYU4obil9ZnVuY3Rpb24gZShuKXty
ZXR1cm57bGVmdDpmdW5jdGlvbih0LGUscix1KXtmb3IoYXJndW1lbnRzLmxlbmd0aDwzJiYocj0w
KSxhcmd1bWVudHMubGVuZ3RoPDQmJih1PXQubGVuZ3RoKTt1PnI7KXt2YXIgaT1yK3U+Pj4xO24o
dFtpXSxlKTwwP3I9aSsxOnU9aX1yZXR1cm4gcn0scmlnaHQ6ZnVuY3Rpb24odCxlLHIsdSl7Zm9y
KGFyZ3VtZW50cy5sZW5ndGg8MyYmKHI9MCksYXJndW1lbnRzLmxlbmd0aDw0JiYodT10Lmxlbmd0
aCk7dT5yOyl7dmFyIGk9cit1Pj4+MTtuKHRbaV0sZSk+MD91PWk6cj1pKzF9cmV0dXJuIHJ9fX1m
dW5jdGlvbiByKG4pe3JldHVybiBuLmxlbmd0aH1mdW5jdGlvbiB1KG4pe2Zvcih2YXIgdD0xO24q
dCUxOyl0Kj0xMDtyZXR1cm4gdH1mdW5jdGlvbiBpKG4sdCl7dHJ5e2Zvcih2YXIgZSBpbiB0KU9i
amVjdC5kZWZpbmVQcm9wZXJ0eShuLnByb3RvdHlwZSxlLHt2YWx1ZTp0W2VdLGVudW1lcmFibGU6
ITF9KX1jYXRjaChyKXtuLnByb3RvdHlwZT10fX1mdW5jdGlvbiBvKCl7fWZ1bmN0aW9uIGEobil7
cmV0dXJuIGhhK24gaW4gdGhpc31mdW5jdGlvbiBjKG4pe3JldHVybiBuPWhhK24sbiBpbiB0aGlz
JiZkZWxldGUgdGhpc1tuXX1mdW5jdGlvbiBzKCl7dmFyIG49W107cmV0dXJuIHRoaXMuZm9yRWFj
aChmdW5jdGlvbih0KXtuLnB1c2godCl9KSxufWZ1bmN0aW9uIGwoKXt2YXIgbj0wO2Zvcih2YXIg
dCBpbiB0aGlzKXQuY2hhckNvZGVBdCgwKT09PWdhJiYrK247cmV0dXJuIG59ZnVuY3Rpb24gZigp
e2Zvcih2YXIgbiBpbiB0aGlzKWlmKG4uY2hhckNvZGVBdCgwKT09PWdhKXJldHVybiExO3JldHVy
biEwfWZ1bmN0aW9uIGgoKXt9ZnVuY3Rpb24gZyhuLHQsZSl7cmV0dXJuIGZ1bmN0aW9uKCl7dmFy
IHI9ZS5hcHBseSh0LGFyZ3VtZW50cyk7cmV0dXJuIHI9PT10P246cn19ZnVuY3Rpb24gcChuLHQp
e2lmKHQgaW4gbilyZXR1cm4gdDt0PXQuY2hhckF0KDApLnRvVXBwZXJDYXNlKCkrdC5zdWJzdHJp
bmcoMSk7Zm9yKHZhciBlPTAscj1wYS5sZW5ndGg7cj5lOysrZSl7dmFyIHU9cGFbZV0rdDtpZih1
IGluIG4pcmV0dXJuIHV9fWZ1bmN0aW9uIHYoKXt9ZnVuY3Rpb24gZCgpe31mdW5jdGlvbiBtKG4p
e2Z1bmN0aW9uIHQoKXtmb3IodmFyIHQscj1lLHU9LTEsaT1yLmxlbmd0aDsrK3U8aTspKHQ9clt1
XS5vbikmJnQuYXBwbHkodGhpcyxhcmd1bWVudHMpO3JldHVybiBufXZhciBlPVtdLHI9bmV3IG87
cmV0dXJuIHQub249ZnVuY3Rpb24odCx1KXt2YXIgaSxvPXIuZ2V0KHQpO3JldHVybiBhcmd1bWVu
dHMubGVuZ3RoPDI/byYmby5vbjoobyYmKG8ub249bnVsbCxlPWUuc2xpY2UoMCxpPWUuaW5kZXhP
ZihvKSkuY29uY2F0KGUuc2xpY2UoaSsxKSksci5yZW1vdmUodCkpLHUmJmUucHVzaChyLnNldCh0
LHtvbjp1fSkpLG4pfSx0fWZ1bmN0aW9uIHkoKXtHby5ldmVudC5wcmV2ZW50RGVmYXVsdCgpfWZ1
bmN0aW9uIHgoKXtmb3IodmFyIG4sdD1Hby5ldmVudDtuPXQuc291cmNlRXZlbnQ7KXQ9bjtyZXR1
cm4gdH1mdW5jdGlvbiBNKG4pe2Zvcih2YXIgdD1uZXcgZCxlPTAscj1hcmd1bWVudHMubGVuZ3Ro
OysrZTxyOyl0W2FyZ3VtZW50c1tlXV09bSh0KTtyZXR1cm4gdC5vZj1mdW5jdGlvbihlLHIpe3Jl
dHVybiBmdW5jdGlvbih1KXt0cnl7dmFyIGk9dS5zb3VyY2VFdmVudD1Hby5ldmVudDt1LnRhcmdl
dD1uLEdvLmV2ZW50PXUsdFt1LnR5cGVdLmFwcGx5KGUscil9ZmluYWxseXtHby5ldmVudD1pfX19
LHR9ZnVuY3Rpb24gXyhuKXtyZXR1cm4gZGEobixfYSksbn1mdW5jdGlvbiBiKG4pe3JldHVybiJm
dW5jdGlvbiI9PXR5cGVvZiBuP246ZnVuY3Rpb24oKXtyZXR1cm4gbWEobix0aGlzKX19ZnVuY3Rp
b24gdyhuKXtyZXR1cm4iZnVuY3Rpb24iPT10eXBlb2Ygbj9uOmZ1bmN0aW9uKCl7cmV0dXJuIHlh
KG4sdGhpcyl9fWZ1bmN0aW9uIFMobix0KXtmdW5jdGlvbiBlKCl7dGhpcy5yZW1vdmVBdHRyaWJ1
dGUobil9ZnVuY3Rpb24gcigpe3RoaXMucmVtb3ZlQXR0cmlidXRlTlMobi5zcGFjZSxuLmxvY2Fs
KX1mdW5jdGlvbiB1KCl7dGhpcy5zZXRBdHRyaWJ1dGUobix0KX1mdW5jdGlvbiBpKCl7dGhpcy5z
ZXRBdHRyaWJ1dGVOUyhuLnNwYWNlLG4ubG9jYWwsdCl9ZnVuY3Rpb24gbygpe3ZhciBlPXQuYXBw
bHkodGhpcyxhcmd1bWVudHMpO251bGw9PWU/dGhpcy5yZW1vdmVBdHRyaWJ1dGUobik6dGhpcy5z
ZXRBdHRyaWJ1dGUobixlKX1mdW5jdGlvbiBhKCl7dmFyIGU9dC5hcHBseSh0aGlzLGFyZ3VtZW50
cyk7bnVsbD09ZT90aGlzLnJlbW92ZUF0dHJpYnV0ZU5TKG4uc3BhY2Usbi5sb2NhbCk6dGhpcy5z
ZXRBdHRyaWJ1dGVOUyhuLnNwYWNlLG4ubG9jYWwsZSl9cmV0dXJuIG49R28ubnMucXVhbGlmeShu
KSxudWxsPT10P24ubG9jYWw/cjplOiJmdW5jdGlvbiI9PXR5cGVvZiB0P24ubG9jYWw/YTpvOm4u
bG9jYWw/aTp1fWZ1bmN0aW9uIGsobil7cmV0dXJuIG4udHJpbSgpLnJlcGxhY2UoL1xzKy9nLCIg
Iil9ZnVuY3Rpb24gRShuKXtyZXR1cm4gbmV3IFJlZ0V4cCgiKD86XnxcXHMrKSIrR28ucmVxdW90
ZShuKSsiKD86XFxzK3wkKSIsImciKX1mdW5jdGlvbiBBKG4pe3JldHVybiBuLnRyaW0oKS5zcGxp
dCgvXnxccysvKX1mdW5jdGlvbiBDKG4sdCl7ZnVuY3Rpb24gZSgpe2Zvcih2YXIgZT0tMTsrK2U8
dTspbltlXSh0aGlzLHQpfWZ1bmN0aW9uIHIoKXtmb3IodmFyIGU9LTEscj10LmFwcGx5KHRoaXMs
YXJndW1lbnRzKTsrK2U8dTspbltlXSh0aGlzLHIpfW49QShuKS5tYXAoTik7dmFyIHU9bi5sZW5n
dGg7cmV0dXJuImZ1bmN0aW9uIj09dHlwZW9mIHQ/cjplfWZ1bmN0aW9uIE4obil7dmFyIHQ9RShu
KTtyZXR1cm4gZnVuY3Rpb24oZSxyKXtpZih1PWUuY2xhc3NMaXN0KXJldHVybiByP3UuYWRkKG4p
OnUucmVtb3ZlKG4pO3ZhciB1PWUuZ2V0QXR0cmlidXRlKCJjbGFzcyIpfHwiIjtyPyh0Lmxhc3RJ
bmRleD0wLHQudGVzdCh1KXx8ZS5zZXRBdHRyaWJ1dGUoImNsYXNzIixrKHUrIiAiK24pKSk6ZS5z
ZXRBdHRyaWJ1dGUoImNsYXNzIixrKHUucmVwbGFjZSh0LCIgIikpKX19ZnVuY3Rpb24gTChuLHQs
ZSl7ZnVuY3Rpb24gcigpe3RoaXMuc3R5bGUucmVtb3ZlUHJvcGVydHkobil9ZnVuY3Rpb24gdSgp
e3RoaXMuc3R5bGUuc2V0UHJvcGVydHkobix0LGUpfWZ1bmN0aW9uIGkoKXt2YXIgcj10LmFwcGx5
KHRoaXMsYXJndW1lbnRzKTtudWxsPT1yP3RoaXMuc3R5bGUucmVtb3ZlUHJvcGVydHkobik6dGhp
cy5zdHlsZS5zZXRQcm9wZXJ0eShuLHIsZSl9cmV0dXJuIG51bGw9PXQ/cjoiZnVuY3Rpb24iPT10
eXBlb2YgdD9pOnV9ZnVuY3Rpb24gVChuLHQpe2Z1bmN0aW9uIGUoKXtkZWxldGUgdGhpc1tuXX1m
dW5jdGlvbiByKCl7dGhpc1tuXT10fWZ1bmN0aW9uIHUoKXt2YXIgZT10LmFwcGx5KHRoaXMsYXJn
dW1lbnRzKTtudWxsPT1lP2RlbGV0ZSB0aGlzW25dOnRoaXNbbl09ZX1yZXR1cm4gbnVsbD09dD9l
OiJmdW5jdGlvbiI9PXR5cGVvZiB0P3U6cn1mdW5jdGlvbiBxKG4pe3JldHVybiJmdW5jdGlvbiI9
PXR5cGVvZiBuP246KG49R28ubnMucXVhbGlmeShuKSkubG9jYWw/ZnVuY3Rpb24oKXtyZXR1cm4g
dGhpcy5vd25lckRvY3VtZW50LmNyZWF0ZUVsZW1lbnROUyhuLnNwYWNlLG4ubG9jYWwpfTpmdW5j
dGlvbigpe3JldHVybiB0aGlzLm93bmVyRG9jdW1lbnQuY3JlYXRlRWxlbWVudE5TKHRoaXMubmFt
ZXNwYWNlVVJJLG4pfX1mdW5jdGlvbiB6KG4pe3JldHVybntfX2RhdGFfXzpufX1mdW5jdGlvbiBS
KG4pe3JldHVybiBmdW5jdGlvbigpe3JldHVybiBNYSh0aGlzLG4pfX1mdW5jdGlvbiBEKHQpe3Jl
dHVybiBhcmd1bWVudHMubGVuZ3RofHwodD1uKSxmdW5jdGlvbihuLGUpe3JldHVybiBuJiZlP3Qo
bi5fX2RhdGFfXyxlLl9fZGF0YV9fKTohbi0hZX19ZnVuY3Rpb24gUChuLHQpe2Zvcih2YXIgZT0w
LHI9bi5sZW5ndGg7cj5lO2UrKylmb3IodmFyIHUsaT1uW2VdLG89MCxhPWkubGVuZ3RoO2E+bztv
KyspKHU9aVtvXSkmJnQodSxvLGUpO3JldHVybiBufWZ1bmN0aW9uIFUobil7cmV0dXJuIGRhKG4s
d2EpLG59ZnVuY3Rpb24gaihuKXt2YXIgdCxlO3JldHVybiBmdW5jdGlvbihyLHUsaSl7dmFyIG8s
YT1uW2ldLnVwZGF0ZSxjPWEubGVuZ3RoO2ZvcihpIT1lJiYoZT1pLHQ9MCksdT49dCYmKHQ9dSsx
KTshKG89YVt0XSkmJisrdDxjOyk7cmV0dXJuIG99fWZ1bmN0aW9uIEgoKXt2YXIgbj10aGlzLl9f
dHJhbnNpdGlvbl9fO24mJisrbi5hY3RpdmV9ZnVuY3Rpb24gRihuLHQsZSl7ZnVuY3Rpb24gcigp
e3ZhciB0PXRoaXNbb107dCYmKHRoaXMucmVtb3ZlRXZlbnRMaXN0ZW5lcihuLHQsdC4kKSxkZWxl
dGUgdGhpc1tvXSl9ZnVuY3Rpb24gdSgpe3ZhciB1PWModCxRbyhhcmd1bWVudHMpKTtyLmNhbGwo
dGhpcyksdGhpcy5hZGRFdmVudExpc3RlbmVyKG4sdGhpc1tvXT11LHUuJD1lKSx1Ll89dH1mdW5j
dGlvbiBpKCl7dmFyIHQsZT1uZXcgUmVnRXhwKCJeX19vbihbXi5dKykiK0dvLnJlcXVvdGUobikr
IiQiKTtmb3IodmFyIHIgaW4gdGhpcylpZih0PXIubWF0Y2goZSkpe3ZhciB1PXRoaXNbcl07dGhp
cy5yZW1vdmVFdmVudExpc3RlbmVyKHRbMV0sdSx1LiQpLGRlbGV0ZSB0aGlzW3JdfX12YXIgbz0i
X19vbiIrbixhPW4uaW5kZXhPZigiLiIpLGM9TzthPjAmJihuPW4uc3Vic3RyaW5nKDAsYSkpO3Zh
ciBzPWthLmdldChuKTtyZXR1cm4gcyYmKG49cyxjPUkpLGE/dD91OnI6dD92Oml9ZnVuY3Rpb24g
TyhuLHQpe3JldHVybiBmdW5jdGlvbihlKXt2YXIgcj1Hby5ldmVudDtHby5ldmVudD1lLHRbMF09
dGhpcy5fX2RhdGFfXzt0cnl7bi5hcHBseSh0aGlzLHQpfWZpbmFsbHl7R28uZXZlbnQ9cn19fWZ1
bmN0aW9uIEkobix0KXt2YXIgZT1PKG4sdCk7cmV0dXJuIGZ1bmN0aW9uKG4pe3ZhciB0PXRoaXMs
cj1uLnJlbGF0ZWRUYXJnZXQ7ciYmKHI9PT10fHw4JnIuY29tcGFyZURvY3VtZW50UG9zaXRpb24o
dCkpfHxlLmNhbGwodCxuKX19ZnVuY3Rpb24gWSgpe3ZhciBuPSIuZHJhZ3N1cHByZXNzLSIrICsr
QWEsdD0iY2xpY2siK24sZT1Hby5zZWxlY3QoZWEpLm9uKCJ0b3VjaG1vdmUiK24seSkub24oImRy
YWdzdGFydCIrbix5KS5vbigic2VsZWN0c3RhcnQiK24seSk7aWYoRWEpe3ZhciByPXRhLnN0eWxl
LHU9cltFYV07cltFYV09Im5vbmUifXJldHVybiBmdW5jdGlvbihpKXtmdW5jdGlvbiBvKCl7ZS5v
bih0LG51bGwpfWUub24obixudWxsKSxFYSYmKHJbRWFdPXUpLGkmJihlLm9uKHQsZnVuY3Rpb24o
KXt5KCksbygpfSwhMCksc2V0VGltZW91dChvLDApKX19ZnVuY3Rpb24gWihuLHQpe3QuY2hhbmdl
ZFRvdWNoZXMmJih0PXQuY2hhbmdlZFRvdWNoZXNbMF0pO3ZhciBlPW4ub3duZXJTVkdFbGVtZW50
fHxuO2lmKGUuY3JlYXRlU1ZHUG9pbnQpe3ZhciByPWUuY3JlYXRlU1ZHUG9pbnQoKTtyZXR1cm4g
ci54PXQuY2xpZW50WCxyLnk9dC5jbGllbnRZLHI9ci5tYXRyaXhUcmFuc2Zvcm0obi5nZXRTY3Jl
ZW5DVE0oKS5pbnZlcnNlKCkpLFtyLngsci55XX12YXIgdT1uLmdldEJvdW5kaW5nQ2xpZW50UmVj
dCgpO3JldHVyblt0LmNsaWVudFgtdS5sZWZ0LW4uY2xpZW50TGVmdCx0LmNsaWVudFktdS50b3At
bi5jbGllbnRUb3BdfWZ1bmN0aW9uIFYoKXtyZXR1cm4gR28uZXZlbnQuY2hhbmdlZFRvdWNoZXNb
MF0uaWRlbnRpZmllcn1mdW5jdGlvbiAkKCl7cmV0dXJuIEdvLmV2ZW50LnRhcmdldH1mdW5jdGlv
biBYKCl7cmV0dXJuIGVhfWZ1bmN0aW9uIEIobil7cmV0dXJuIG4+MD8xOjA+bj8tMTowfWZ1bmN0
aW9uIEoobix0LGUpe3JldHVybih0WzBdLW5bMF0pKihlWzFdLW5bMV0pLSh0WzFdLW5bMV0pKihl
WzBdLW5bMF0pfWZ1bmN0aW9uIFcobil7cmV0dXJuIG4+MT8wOi0xPm4/Q2E6TWF0aC5hY29zKG4p
fWZ1bmN0aW9uIEcobil7cmV0dXJuIG4+MT9MYTotMT5uPy1MYTpNYXRoLmFzaW4obil9ZnVuY3Rp
b24gSyhuKXtyZXR1cm4oKG49TWF0aC5leHAobikpLTEvbikvMn1mdW5jdGlvbiBRKG4pe3JldHVy
bigobj1NYXRoLmV4cChuKSkrMS9uKS8yfWZ1bmN0aW9uIG50KG4pe3JldHVybigobj1NYXRoLmV4
cCgyKm4pKS0xKS8obisxKX1mdW5jdGlvbiB0dChuKXtyZXR1cm4obj1NYXRoLnNpbihuLzIpKSpu
fWZ1bmN0aW9uIGV0KCl7fWZ1bmN0aW9uIHJ0KG4sdCxlKXtyZXR1cm4gbmV3IHV0KG4sdCxlKX1m
dW5jdGlvbiB1dChuLHQsZSl7dGhpcy5oPW4sdGhpcy5zPXQsdGhpcy5sPWV9ZnVuY3Rpb24gaXQo
bix0LGUpe2Z1bmN0aW9uIHIobil7cmV0dXJuIG4+MzYwP24tPTM2MDowPm4mJihuKz0zNjApLDYw
Pm4/aSsoby1pKSpuLzYwOjE4MD5uP286MjQwPm4/aSsoby1pKSooMjQwLW4pLzYwOml9ZnVuY3Rp
b24gdShuKXtyZXR1cm4gTWF0aC5yb3VuZCgyNTUqcihuKSl9dmFyIGksbztyZXR1cm4gbj1pc05h
TihuKT8wOihuJT0zNjApPDA/biszNjA6bix0PWlzTmFOKHQpPzA6MD50PzA6dD4xPzE6dCxlPTA+
ZT8wOmU+MT8xOmUsbz0uNT49ZT9lKigxK3QpOmUrdC1lKnQsaT0yKmUtbyx5dCh1KG4rMTIwKSx1
KG4pLHUobi0xMjApKX1mdW5jdGlvbiBvdChuLHQsZSl7cmV0dXJuIG5ldyBhdChuLHQsZSl9ZnVu
Y3Rpb24gYXQobix0LGUpe3RoaXMuaD1uLHRoaXMuYz10LHRoaXMubD1lfWZ1bmN0aW9uIGN0KG4s
dCxlKXtyZXR1cm4gaXNOYU4obikmJihuPTApLGlzTmFOKHQpJiYodD0wKSxzdChlLE1hdGguY29z
KG4qPXphKSp0LE1hdGguc2luKG4pKnQpfWZ1bmN0aW9uIHN0KG4sdCxlKXtyZXR1cm4gbmV3IGx0
KG4sdCxlKX1mdW5jdGlvbiBsdChuLHQsZSl7dGhpcy5sPW4sdGhpcy5hPXQsdGhpcy5iPWV9ZnVu
Y3Rpb24gZnQobix0LGUpe3ZhciByPShuKzE2KS8xMTYsdT1yK3QvNTAwLGk9ci1lLzIwMDtyZXR1
cm4gdT1ndCh1KSpaYSxyPWd0KHIpKlZhLGk9Z3QoaSkqJGEseXQodnQoMy4yNDA0NTQyKnUtMS41
MzcxMzg1KnItLjQ5ODUzMTQqaSksdnQoLS45NjkyNjYqdSsxLjg3NjAxMDgqcisuMDQxNTU2Kmkp
LHZ0KC4wNTU2NDM0KnUtLjIwNDAyNTkqcisxLjA1NzIyNTIqaSkpfWZ1bmN0aW9uIGh0KG4sdCxl
KXtyZXR1cm4gbj4wP290KE1hdGguYXRhbjIoZSx0KSpSYSxNYXRoLnNxcnQodCp0K2UqZSksbik6
b3QoMC8wLDAvMCxuKX1mdW5jdGlvbiBndChuKXtyZXR1cm4gbj4uMjA2ODkzMDM0P24qbipuOihu
LTQvMjkpLzcuNzg3MDM3fWZ1bmN0aW9uIHB0KG4pe3JldHVybiBuPi4wMDg4NTY/TWF0aC5wb3co
biwxLzMpOjcuNzg3MDM3Km4rNC8yOX1mdW5jdGlvbiB2dChuKXtyZXR1cm4gTWF0aC5yb3VuZCgy
NTUqKC4wMDMwND49bj8xMi45MipuOjEuMDU1Kk1hdGgucG93KG4sMS8yLjQpLS4wNTUpKX1mdW5j
dGlvbiBkdChuKXtyZXR1cm4geXQobj4+MTYsMjU1Jm4+PjgsMjU1Jm4pfWZ1bmN0aW9uIG10KG4p
e3JldHVybiBkdChuKSsiIn1mdW5jdGlvbiB5dChuLHQsZSl7cmV0dXJuIG5ldyB4dChuLHQsZSl9
ZnVuY3Rpb24geHQobix0LGUpe3RoaXMucj1uLHRoaXMuZz10LHRoaXMuYj1lfWZ1bmN0aW9uIE10
KG4pe3JldHVybiAxNj5uPyIwIitNYXRoLm1heCgwLG4pLnRvU3RyaW5nKDE2KTpNYXRoLm1pbigy
NTUsbikudG9TdHJpbmcoMTYpfWZ1bmN0aW9uIF90KG4sdCxlKXt2YXIgcix1LGksbz0wLGE9MCxj
PTA7aWYocj0vKFthLXpdKylcKCguKilcKS9pLmV4ZWMobikpc3dpdGNoKHU9clsyXS5zcGxpdCgi
LCIpLHJbMV0pe2Nhc2UiaHNsIjpyZXR1cm4gZShwYXJzZUZsb2F0KHVbMF0pLHBhcnNlRmxvYXQo
dVsxXSkvMTAwLHBhcnNlRmxvYXQodVsyXSkvMTAwKTtjYXNlInJnYiI6cmV0dXJuIHQoa3QodVsw
XSksa3QodVsxXSksa3QodVsyXSkpfXJldHVybihpPUphLmdldChuKSk/dChpLnIsaS5nLGkuYik6
KG51bGw9PW58fCIjIiE9PW4uY2hhckF0KDApfHxpc05hTihpPXBhcnNlSW50KG4uc3Vic3RyaW5n
KDEpLDE2KSl8fCg0PT09bi5sZW5ndGg/KG89KDM4NDAmaSk+PjQsbz1vPj40fG8sYT0yNDAmaSxh
PWE+PjR8YSxjPTE1JmksYz1jPDw0fGMpOjc9PT1uLmxlbmd0aCYmKG89KDE2NzExNjgwJmkpPj4x
NixhPSg2NTI4MCZpKT4+OCxjPTI1NSZpKSksdChvLGEsYykpfWZ1bmN0aW9uIGJ0KG4sdCxlKXt2
YXIgcix1LGk9TWF0aC5taW4obi89MjU1LHQvPTI1NSxlLz0yNTUpLG89TWF0aC5tYXgobix0LGUp
LGE9by1pLGM9KG8raSkvMjtyZXR1cm4gYT8odT0uNT5jP2EvKG8raSk6YS8oMi1vLWkpLHI9bj09
bz8odC1lKS9hKyhlPnQ/NjowKTp0PT1vPyhlLW4pL2ErMjoobi10KS9hKzQscio9NjApOihyPTAv
MCx1PWM+MCYmMT5jPzA6cikscnQocix1LGMpfWZ1bmN0aW9uIHd0KG4sdCxlKXtuPVN0KG4pLHQ9
U3QodCksZT1TdChlKTt2YXIgcj1wdCgoLjQxMjQ1NjQqbisuMzU3NTc2MSp0Ky4xODA0Mzc1KmUp
L1phKSx1PXB0KCguMjEyNjcyOSpuKy43MTUxNTIyKnQrLjA3MjE3NSplKS9WYSksaT1wdCgoLjAx
OTMzMzkqbisuMTE5MTkyKnQrLjk1MDMwNDEqZSkvJGEpO3JldHVybiBzdCgxMTYqdS0xNiw1MDAq
KHItdSksMjAwKih1LWkpKX1mdW5jdGlvbiBTdChuKXtyZXR1cm4obi89MjU1KTw9LjA0MDQ1P24v
MTIuOTI6TWF0aC5wb3coKG4rLjA1NSkvMS4wNTUsMi40KX1mdW5jdGlvbiBrdChuKXt2YXIgdD1w
YXJzZUZsb2F0KG4pO3JldHVybiIlIj09PW4uY2hhckF0KG4ubGVuZ3RoLTEpP01hdGgucm91bmQo
Mi41NSp0KTp0fWZ1bmN0aW9uIEV0KG4pe3JldHVybiJmdW5jdGlvbiI9PXR5cGVvZiBuP246ZnVu
Y3Rpb24oKXtyZXR1cm4gbn19ZnVuY3Rpb24gQXQobil7cmV0dXJuIG59ZnVuY3Rpb24gQ3Qobil7
cmV0dXJuIGZ1bmN0aW9uKHQsZSxyKXtyZXR1cm4gMj09PWFyZ3VtZW50cy5sZW5ndGgmJiJmdW5j
dGlvbiI9PXR5cGVvZiBlJiYocj1lLGU9bnVsbCksTnQodCxlLG4scil9fWZ1bmN0aW9uIE50KG4s
dCxlLHIpe2Z1bmN0aW9uIHUoKXt2YXIgbix0PWMuc3RhdHVzO2lmKCF0JiZjLnJlc3BvbnNlVGV4
dHx8dD49MjAwJiYzMDA+dHx8MzA0PT09dCl7dHJ5e249ZS5jYWxsKGksYyl9Y2F0Y2gocil7cmV0
dXJuIG8uZXJyb3IuY2FsbChpLHIpLHZvaWQgMH1vLmxvYWQuY2FsbChpLG4pfWVsc2Ugby5lcnJv
ci5jYWxsKGksYyl9dmFyIGk9e30sbz1Hby5kaXNwYXRjaCgiYmVmb3Jlc2VuZCIsInByb2dyZXNz
IiwibG9hZCIsImVycm9yIiksYT17fSxjPW5ldyBYTUxIdHRwUmVxdWVzdCxzPW51bGw7cmV0dXJu
IWVhLlhEb21haW5SZXF1ZXN0fHwid2l0aENyZWRlbnRpYWxzImluIGN8fCEvXihodHRwKHMpPzop
P1wvXC8vLnRlc3Qobil8fChjPW5ldyBYRG9tYWluUmVxdWVzdCksIm9ubG9hZCJpbiBjP2Mub25s
b2FkPWMub25lcnJvcj11OmMub25yZWFkeXN0YXRlY2hhbmdlPWZ1bmN0aW9uKCl7Yy5yZWFkeVN0
YXRlPjMmJnUoKX0sYy5vbnByb2dyZXNzPWZ1bmN0aW9uKG4pe3ZhciB0PUdvLmV2ZW50O0dvLmV2
ZW50PW47dHJ5e28ucHJvZ3Jlc3MuY2FsbChpLGMpfWZpbmFsbHl7R28uZXZlbnQ9dH19LGkuaGVh
ZGVyPWZ1bmN0aW9uKG4sdCl7cmV0dXJuIG49KG4rIiIpLnRvTG93ZXJDYXNlKCksYXJndW1lbnRz
Lmxlbmd0aDwyP2Fbbl06KG51bGw9PXQ/ZGVsZXRlIGFbbl06YVtuXT10KyIiLGkpfSxpLm1pbWVU
eXBlPWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyh0PW51bGw9PW4/bnVsbDpu
KyIiLGkpOnR9LGkucmVzcG9uc2VUeXBlPWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVu
Z3RoPyhzPW4saSk6c30saS5yZXNwb25zZT1mdW5jdGlvbihuKXtyZXR1cm4gZT1uLGl9LFsiZ2V0
IiwicG9zdCJdLmZvckVhY2goZnVuY3Rpb24obil7aVtuXT1mdW5jdGlvbigpe3JldHVybiBpLnNl
bmQuYXBwbHkoaSxbbl0uY29uY2F0KFFvKGFyZ3VtZW50cykpKX19KSxpLnNlbmQ9ZnVuY3Rpb24o
ZSxyLHUpe2lmKDI9PT1hcmd1bWVudHMubGVuZ3RoJiYiZnVuY3Rpb24iPT10eXBlb2YgciYmKHU9
cixyPW51bGwpLGMub3BlbihlLG4sITApLG51bGw9PXR8fCJhY2NlcHQiaW4gYXx8KGEuYWNjZXB0
PXQrIiwqLyoiKSxjLnNldFJlcXVlc3RIZWFkZXIpZm9yKHZhciBsIGluIGEpYy5zZXRSZXF1ZXN0
SGVhZGVyKGwsYVtsXSk7cmV0dXJuIG51bGwhPXQmJmMub3ZlcnJpZGVNaW1lVHlwZSYmYy5vdmVy
cmlkZU1pbWVUeXBlKHQpLG51bGwhPXMmJihjLnJlc3BvbnNlVHlwZT1zKSxudWxsIT11JiZpLm9u
KCJlcnJvciIsdSkub24oImxvYWQiLGZ1bmN0aW9uKG4pe3UobnVsbCxuKX0pLG8uYmVmb3Jlc2Vu
ZC5jYWxsKGksYyksYy5zZW5kKG51bGw9PXI/bnVsbDpyKSxpfSxpLmFib3J0PWZ1bmN0aW9uKCl7
cmV0dXJuIGMuYWJvcnQoKSxpfSxHby5yZWJpbmQoaSxvLCJvbiIpLG51bGw9PXI/aTppLmdldChM
dChyKSl9ZnVuY3Rpb24gTHQobil7cmV0dXJuIDE9PT1uLmxlbmd0aD9mdW5jdGlvbih0LGUpe24o
bnVsbD09dD9lOm51bGwpfTpufWZ1bmN0aW9uIFR0KCl7dmFyIG49cXQoKSx0PXp0KCktbjt0PjI0
Pyhpc0Zpbml0ZSh0KSYmKGNsZWFyVGltZW91dChRYSksUWE9c2V0VGltZW91dChUdCx0KSksS2E9
MCk6KEthPTEsdGMoVHQpKX1mdW5jdGlvbiBxdCgpe3ZhciBuPURhdGUubm93KCk7Zm9yKG5jPVdh
O25jOyluPj1uYy50JiYobmMuZj1uYy5jKG4tbmMudCkpLG5jPW5jLm47cmV0dXJuIG59ZnVuY3Rp
b24genQoKXtmb3IodmFyIG4sdD1XYSxlPTEvMDt0Oyl0LmY/dD1uP24ubj10Lm46V2E9dC5uOih0
LnQ8ZSYmKGU9dC50KSx0PShuPXQpLm4pO3JldHVybiBHYT1uLGV9ZnVuY3Rpb24gUnQobix0KXty
ZXR1cm4gdC0obj9NYXRoLmNlaWwoTWF0aC5sb2cobikvTWF0aC5MTjEwKToxKX1mdW5jdGlvbiBE
dChuLHQpe3ZhciBlPU1hdGgucG93KDEwLDMqZmEoOC10KSk7cmV0dXJue3NjYWxlOnQ+OD9mdW5j
dGlvbihuKXtyZXR1cm4gbi9lfTpmdW5jdGlvbihuKXtyZXR1cm4gbiplfSxzeW1ib2w6bn19ZnVu
Y3Rpb24gUHQobil7dmFyIHQ9bi5kZWNpbWFsLGU9bi50aG91c2FuZHMscj1uLmdyb3VwaW5nLHU9
bi5jdXJyZW5jeSxpPXI/ZnVuY3Rpb24obil7Zm9yKHZhciB0PW4ubGVuZ3RoLHU9W10saT0wLG89
clswXTt0PjAmJm8+MDspdS5wdXNoKG4uc3Vic3RyaW5nKHQtPW8sdCtvKSksbz1yW2k9KGkrMSkl
ci5sZW5ndGhdO3JldHVybiB1LnJldmVyc2UoKS5qb2luKGUpfTpBdDtyZXR1cm4gZnVuY3Rpb24o
bil7dmFyIGU9cmMuZXhlYyhuKSxyPWVbMV18fCIgIixvPWVbMl18fCI+IixhPWVbM118fCIiLGM9
ZVs0XXx8IiIscz1lWzVdLGw9K2VbNl0sZj1lWzddLGg9ZVs4XSxnPWVbOV0scD0xLHY9IiIsZD0i
IixtPSExO3N3aXRjaChoJiYoaD0raC5zdWJzdHJpbmcoMSkpLChzfHwiMCI9PT1yJiYiPSI9PT1v
KSYmKHM9cj0iMCIsbz0iPSIsZiYmKGwtPU1hdGguZmxvb3IoKGwtMSkvNCkpKSxnKXtjYXNlIm4i
OmY9ITAsZz0iZyI7YnJlYWs7Y2FzZSIlIjpwPTEwMCxkPSIlIixnPSJmIjticmVhaztjYXNlInAi
OnA9MTAwLGQ9IiUiLGc9InIiO2JyZWFrO2Nhc2UiYiI6Y2FzZSJvIjpjYXNlIngiOmNhc2UiWCI6
IiMiPT09YyYmKHY9IjAiK2cudG9Mb3dlckNhc2UoKSk7Y2FzZSJjIjpjYXNlImQiOm09ITAsaD0w
O2JyZWFrO2Nhc2UicyI6cD0tMSxnPSJyIn0iJCI9PT1jJiYodj11WzBdLGQ9dVsxXSksInIiIT1n
fHxofHwoZz0iZyIpLG51bGwhPWgmJigiZyI9PWc/aD1NYXRoLm1heCgxLE1hdGgubWluKDIxLGgp
KTooImUiPT1nfHwiZiI9PWcpJiYoaD1NYXRoLm1heCgwLE1hdGgubWluKDIwLGgpKSkpLGc9dWMu
Z2V0KGcpfHxVdDt2YXIgeT1zJiZmO3JldHVybiBmdW5jdGlvbihuKXt2YXIgZT1kO2lmKG0mJm4l
MSlyZXR1cm4iIjt2YXIgdT0wPm58fDA9PT1uJiYwPjEvbj8obj0tbiwiLSIpOmE7aWYoMD5wKXt2
YXIgYz1Hby5mb3JtYXRQcmVmaXgobixoKTtuPWMuc2NhbGUobiksZT1jLnN5bWJvbCtkfWVsc2Ug
bio9cDtuPWcobixoKTt2YXIgeD1uLmxhc3RJbmRleE9mKCIuIiksTT0wPng/bjpuLnN1YnN0cmlu
ZygwLHgpLF89MD54PyIiOnQrbi5zdWJzdHJpbmcoeCsxKTshcyYmZiYmKE09aShNKSk7dmFyIGI9
di5sZW5ndGgrTS5sZW5ndGgrXy5sZW5ndGgrKHk/MDp1Lmxlbmd0aCksdz1sPmI/bmV3IEFycmF5
KGI9bC1iKzEpLmpvaW4ocik6IiI7cmV0dXJuIHkmJihNPWkodytNKSksdSs9dixuPU0rXywoIjwi
PT09bz91K24rdzoiPiI9PT1vP3crdStuOiJeIj09PW8/dy5zdWJzdHJpbmcoMCxiPj49MSkrdStu
K3cuc3Vic3RyaW5nKGIpOnUrKHk/bjp3K24pKStlfX19ZnVuY3Rpb24gVXQobil7cmV0dXJuIG4r
IiJ9ZnVuY3Rpb24ganQoKXt0aGlzLl89bmV3IERhdGUoYXJndW1lbnRzLmxlbmd0aD4xP0RhdGUu
VVRDLmFwcGx5KHRoaXMsYXJndW1lbnRzKTphcmd1bWVudHNbMF0pfWZ1bmN0aW9uIEh0KG4sdCxl
KXtmdW5jdGlvbiByKHQpe3ZhciBlPW4odCkscj1pKGUsMSk7cmV0dXJuIHItdD50LWU/ZTpyfWZ1
bmN0aW9uIHUoZSl7cmV0dXJuIHQoZT1uKG5ldyBvYyhlLTEpKSwxKSxlfWZ1bmN0aW9uIGkobixl
KXtyZXR1cm4gdChuPW5ldyBvYygrbiksZSksbn1mdW5jdGlvbiBvKG4scixpKXt2YXIgbz11KG4p
LGE9W107aWYoaT4xKWZvcig7cj5vOyllKG8pJWl8fGEucHVzaChuZXcgRGF0ZSgrbykpLHQobywx
KTtlbHNlIGZvcig7cj5vOylhLnB1c2gobmV3IERhdGUoK28pKSx0KG8sMSk7cmV0dXJuIGF9ZnVu
Y3Rpb24gYShuLHQsZSl7dHJ5e29jPWp0O3ZhciByPW5ldyBqdDtyZXR1cm4gci5fPW4sbyhyLHQs
ZSl9ZmluYWxseXtvYz1EYXRlfX1uLmZsb29yPW4sbi5yb3VuZD1yLG4uY2VpbD11LG4ub2Zmc2V0
PWksbi5yYW5nZT1vO3ZhciBjPW4udXRjPUZ0KG4pO3JldHVybiBjLmZsb29yPWMsYy5yb3VuZD1G
dChyKSxjLmNlaWw9RnQodSksYy5vZmZzZXQ9RnQoaSksYy5yYW5nZT1hLG59ZnVuY3Rpb24gRnQo
bil7cmV0dXJuIGZ1bmN0aW9uKHQsZSl7dHJ5e29jPWp0O3ZhciByPW5ldyBqdDtyZXR1cm4gci5f
PXQsbihyLGUpLl99ZmluYWxseXtvYz1EYXRlfX19ZnVuY3Rpb24gT3Qobil7ZnVuY3Rpb24gdChu
KXtmdW5jdGlvbiB0KHQpe2Zvcih2YXIgZSx1LGksbz1bXSxhPS0xLGM9MDsrK2E8cjspMzc9PT1u
LmNoYXJDb2RlQXQoYSkmJihvLnB1c2gobi5zdWJzdHJpbmcoYyxhKSksbnVsbCE9KHU9Y2NbZT1u
LmNoYXJBdCgrK2EpXSkmJihlPW4uY2hhckF0KCsrYSkpLChpPUNbZV0pJiYoZT1pKHQsbnVsbD09
dT8iZSI9PT1lPyIgIjoiMCI6dSkpLG8ucHVzaChlKSxjPWErMSk7cmV0dXJuIG8ucHVzaChuLnN1
YnN0cmluZyhjLGEpKSxvLmpvaW4oIiIpfXZhciByPW4ubGVuZ3RoO3JldHVybiB0LnBhcnNlPWZ1
bmN0aW9uKHQpe3ZhciByPXt5OjE5MDAsbTowLGQ6MSxIOjAsTTowLFM6MCxMOjAsWjpudWxsfSx1
PWUocixuLHQsMCk7aWYodSE9dC5sZW5ndGgpcmV0dXJuIG51bGw7InAiaW4gciYmKHIuSD1yLkgl
MTIrMTIqci5wKTt2YXIgaT1udWxsIT1yLlomJm9jIT09anQsbz1uZXcoaT9qdDpvYyk7cmV0dXJu
ImoiaW4gcj9vLnNldEZ1bGxZZWFyKHIueSwwLHIuaik6InciaW4gciYmKCJXImluIHJ8fCJVImlu
IHIpPyhvLnNldEZ1bGxZZWFyKHIueSwwLDEpLG8uc2V0RnVsbFllYXIoci55LDAsIlciaW4gcj8o
ci53KzYpJTcrNypyLlctKG8uZ2V0RGF5KCkrNSklNzpyLncrNypyLlUtKG8uZ2V0RGF5KCkrNikl
NykpOm8uc2V0RnVsbFllYXIoci55LHIubSxyLmQpLG8uc2V0SG91cnMoci5IK01hdGguZmxvb3Io
ci5aLzEwMCksci5NK3IuWiUxMDAsci5TLHIuTCksaT9vLl86b30sdC50b1N0cmluZz1mdW5jdGlv
bigpe3JldHVybiBufSx0fWZ1bmN0aW9uIGUobix0LGUscil7Zm9yKHZhciB1LGksbyxhPTAsYz10
Lmxlbmd0aCxzPWUubGVuZ3RoO2M+YTspe2lmKHI+PXMpcmV0dXJuLTE7aWYodT10LmNoYXJDb2Rl
QXQoYSsrKSwzNz09PXUpe2lmKG89dC5jaGFyQXQoYSsrKSxpPU5bbyBpbiBjYz90LmNoYXJBdChh
KyspOm9dLCFpfHwocj1pKG4sZSxyKSk8MClyZXR1cm4tMX1lbHNlIGlmKHUhPWUuY2hhckNvZGVB
dChyKyspKXJldHVybi0xfXJldHVybiByfWZ1bmN0aW9uIHIobix0LGUpe2IubGFzdEluZGV4PTA7
dmFyIHI9Yi5leGVjKHQuc3Vic3RyaW5nKGUpKTtyZXR1cm4gcj8obi53PXcuZ2V0KHJbMF0udG9M
b3dlckNhc2UoKSksZStyWzBdLmxlbmd0aCk6LTF9ZnVuY3Rpb24gdShuLHQsZSl7TS5sYXN0SW5k
ZXg9MDt2YXIgcj1NLmV4ZWModC5zdWJzdHJpbmcoZSkpO3JldHVybiByPyhuLnc9Xy5nZXQoclsw
XS50b0xvd2VyQ2FzZSgpKSxlK3JbMF0ubGVuZ3RoKTotMX1mdW5jdGlvbiBpKG4sdCxlKXtFLmxh
c3RJbmRleD0wO3ZhciByPUUuZXhlYyh0LnN1YnN0cmluZyhlKSk7cmV0dXJuIHI/KG4ubT1BLmdl
dChyWzBdLnRvTG93ZXJDYXNlKCkpLGUrclswXS5sZW5ndGgpOi0xfWZ1bmN0aW9uIG8obix0LGUp
e1MubGFzdEluZGV4PTA7dmFyIHI9Uy5leGVjKHQuc3Vic3RyaW5nKGUpKTtyZXR1cm4gcj8obi5t
PWsuZ2V0KHJbMF0udG9Mb3dlckNhc2UoKSksZStyWzBdLmxlbmd0aCk6LTF9ZnVuY3Rpb24gYShu
LHQscil7cmV0dXJuIGUobixDLmMudG9TdHJpbmcoKSx0LHIpfWZ1bmN0aW9uIGMobix0LHIpe3Jl
dHVybiBlKG4sQy54LnRvU3RyaW5nKCksdCxyKX1mdW5jdGlvbiBzKG4sdCxyKXtyZXR1cm4gZShu
LEMuWC50b1N0cmluZygpLHQscil9ZnVuY3Rpb24gbChuLHQsZSl7dmFyIHI9eC5nZXQodC5zdWJz
dHJpbmcoZSxlKz0yKS50b0xvd2VyQ2FzZSgpKTtyZXR1cm4gbnVsbD09cj8tMToobi5wPXIsZSl9
dmFyIGY9bi5kYXRlVGltZSxoPW4uZGF0ZSxnPW4udGltZSxwPW4ucGVyaW9kcyx2PW4uZGF5cyxk
PW4uc2hvcnREYXlzLG09bi5tb250aHMseT1uLnNob3J0TW9udGhzO3QudXRjPWZ1bmN0aW9uKG4p
e2Z1bmN0aW9uIGUobil7dHJ5e29jPWp0O3ZhciB0PW5ldyBvYztyZXR1cm4gdC5fPW4scih0KX1m
aW5hbGx5e29jPURhdGV9fXZhciByPXQobik7cmV0dXJuIGUucGFyc2U9ZnVuY3Rpb24obil7dHJ5
e29jPWp0O3ZhciB0PXIucGFyc2Uobik7cmV0dXJuIHQmJnQuX31maW5hbGx5e29jPURhdGV9fSxl
LnRvU3RyaW5nPXIudG9TdHJpbmcsZX0sdC5tdWx0aT10LnV0Yy5tdWx0aT1hZTt2YXIgeD1Hby5t
YXAoKSxNPVl0KHYpLF89WnQodiksYj1ZdChkKSx3PVp0KGQpLFM9WXQobSksaz1adChtKSxFPVl0
KHkpLEE9WnQoeSk7cC5mb3JFYWNoKGZ1bmN0aW9uKG4sdCl7eC5zZXQobi50b0xvd2VyQ2FzZSgp
LHQpfSk7dmFyIEM9e2E6ZnVuY3Rpb24obil7cmV0dXJuIGRbbi5nZXREYXkoKV19LEE6ZnVuY3Rp
b24obil7cmV0dXJuIHZbbi5nZXREYXkoKV19LGI6ZnVuY3Rpb24obil7cmV0dXJuIHlbbi5nZXRN
b250aCgpXX0sQjpmdW5jdGlvbihuKXtyZXR1cm4gbVtuLmdldE1vbnRoKCldfSxjOnQoZiksZDpm
dW5jdGlvbihuLHQpe3JldHVybiBJdChuLmdldERhdGUoKSx0LDIpfSxlOmZ1bmN0aW9uKG4sdCl7
cmV0dXJuIEl0KG4uZ2V0RGF0ZSgpLHQsMil9LEg6ZnVuY3Rpb24obix0KXtyZXR1cm4gSXQobi5n
ZXRIb3VycygpLHQsMil9LEk6ZnVuY3Rpb24obix0KXtyZXR1cm4gSXQobi5nZXRIb3VycygpJTEy
fHwxMix0LDIpfSxqOmZ1bmN0aW9uKG4sdCl7cmV0dXJuIEl0KDEraWMuZGF5T2ZZZWFyKG4pLHQs
Myl9LEw6ZnVuY3Rpb24obix0KXtyZXR1cm4gSXQobi5nZXRNaWxsaXNlY29uZHMoKSx0LDMpfSxt
OmZ1bmN0aW9uKG4sdCl7cmV0dXJuIEl0KG4uZ2V0TW9udGgoKSsxLHQsMil9LE06ZnVuY3Rpb24o
bix0KXtyZXR1cm4gSXQobi5nZXRNaW51dGVzKCksdCwyKX0scDpmdW5jdGlvbihuKXtyZXR1cm4g
cFsrKG4uZ2V0SG91cnMoKT49MTIpXX0sUzpmdW5jdGlvbihuLHQpe3JldHVybiBJdChuLmdldFNl
Y29uZHMoKSx0LDIpfSxVOmZ1bmN0aW9uKG4sdCl7cmV0dXJuIEl0KGljLnN1bmRheU9mWWVhcihu
KSx0LDIpfSx3OmZ1bmN0aW9uKG4pe3JldHVybiBuLmdldERheSgpfSxXOmZ1bmN0aW9uKG4sdCl7
cmV0dXJuIEl0KGljLm1vbmRheU9mWWVhcihuKSx0LDIpfSx4OnQoaCksWDp0KGcpLHk6ZnVuY3Rp
b24obix0KXtyZXR1cm4gSXQobi5nZXRGdWxsWWVhcigpJTEwMCx0LDIpfSxZOmZ1bmN0aW9uKG4s
dCl7cmV0dXJuIEl0KG4uZ2V0RnVsbFllYXIoKSUxZTQsdCw0KX0sWjppZSwiJSI6ZnVuY3Rpb24o
KXtyZXR1cm4iJSJ9fSxOPXthOnIsQTp1LGI6aSxCOm8sYzphLGQ6UXQsZTpRdCxIOnRlLEk6dGUs
ajpuZSxMOnVlLG06S3QsTTplZSxwOmwsUzpyZSxVOiR0LHc6VnQsVzpYdCx4OmMsWDpzLHk6SnQs
WTpCdCxaOld0LCIlIjpvZX07cmV0dXJuIHR9ZnVuY3Rpb24gSXQobix0LGUpe3ZhciByPTA+bj8i
LSI6IiIsdT0ocj8tbjpuKSsiIixpPXUubGVuZ3RoO3JldHVybiByKyhlPmk/bmV3IEFycmF5KGUt
aSsxKS5qb2luKHQpK3U6dSl9ZnVuY3Rpb24gWXQobil7cmV0dXJuIG5ldyBSZWdFeHAoIl4oPzoi
K24ubWFwKEdvLnJlcXVvdGUpLmpvaW4oInwiKSsiKSIsImkiKX1mdW5jdGlvbiBadChuKXtmb3Io
dmFyIHQ9bmV3IG8sZT0tMSxyPW4ubGVuZ3RoOysrZTxyOyl0LnNldChuW2VdLnRvTG93ZXJDYXNl
KCksZSk7cmV0dXJuIHR9ZnVuY3Rpb24gVnQobix0LGUpe3NjLmxhc3RJbmRleD0wO3ZhciByPXNj
LmV4ZWModC5zdWJzdHJpbmcoZSxlKzEpKTtyZXR1cm4gcj8obi53PStyWzBdLGUrclswXS5sZW5n
dGgpOi0xfWZ1bmN0aW9uICR0KG4sdCxlKXtzYy5sYXN0SW5kZXg9MDt2YXIgcj1zYy5leGVjKHQu
c3Vic3RyaW5nKGUpKTtyZXR1cm4gcj8obi5VPStyWzBdLGUrclswXS5sZW5ndGgpOi0xfWZ1bmN0
aW9uIFh0KG4sdCxlKXtzYy5sYXN0SW5kZXg9MDt2YXIgcj1zYy5leGVjKHQuc3Vic3RyaW5nKGUp
KTtyZXR1cm4gcj8obi5XPStyWzBdLGUrclswXS5sZW5ndGgpOi0xfWZ1bmN0aW9uIEJ0KG4sdCxl
KXtzYy5sYXN0SW5kZXg9MDt2YXIgcj1zYy5leGVjKHQuc3Vic3RyaW5nKGUsZSs0KSk7cmV0dXJu
IHI/KG4ueT0rclswXSxlK3JbMF0ubGVuZ3RoKTotMX1mdW5jdGlvbiBKdChuLHQsZSl7c2MubGFz
dEluZGV4PTA7dmFyIHI9c2MuZXhlYyh0LnN1YnN0cmluZyhlLGUrMikpO3JldHVybiByPyhuLnk9
R3QoK3JbMF0pLGUrclswXS5sZW5ndGgpOi0xfWZ1bmN0aW9uIFd0KG4sdCxlKXtyZXR1cm4vXlsr
LV1cZHs0fSQvLnRlc3QodD10LnN1YnN0cmluZyhlLGUrNSkpPyhuLlo9LXQsZSs1KTotMX1mdW5j
dGlvbiBHdChuKXtyZXR1cm4gbisobj42OD8xOTAwOjJlMyl9ZnVuY3Rpb24gS3Qobix0LGUpe3Nj
Lmxhc3RJbmRleD0wO3ZhciByPXNjLmV4ZWModC5zdWJzdHJpbmcoZSxlKzIpKTtyZXR1cm4gcj8o
bi5tPXJbMF0tMSxlK3JbMF0ubGVuZ3RoKTotMX1mdW5jdGlvbiBRdChuLHQsZSl7c2MubGFzdElu
ZGV4PTA7dmFyIHI9c2MuZXhlYyh0LnN1YnN0cmluZyhlLGUrMikpO3JldHVybiByPyhuLmQ9K3Jb
MF0sZStyWzBdLmxlbmd0aCk6LTF9ZnVuY3Rpb24gbmUobix0LGUpe3NjLmxhc3RJbmRleD0wO3Zh
ciByPXNjLmV4ZWModC5zdWJzdHJpbmcoZSxlKzMpKTtyZXR1cm4gcj8obi5qPStyWzBdLGUrclsw
XS5sZW5ndGgpOi0xfWZ1bmN0aW9uIHRlKG4sdCxlKXtzYy5sYXN0SW5kZXg9MDt2YXIgcj1zYy5l
eGVjKHQuc3Vic3RyaW5nKGUsZSsyKSk7cmV0dXJuIHI/KG4uSD0rclswXSxlK3JbMF0ubGVuZ3Ro
KTotMX1mdW5jdGlvbiBlZShuLHQsZSl7c2MubGFzdEluZGV4PTA7dmFyIHI9c2MuZXhlYyh0LnN1
YnN0cmluZyhlLGUrMikpO3JldHVybiByPyhuLk09K3JbMF0sZStyWzBdLmxlbmd0aCk6LTF9ZnVu
Y3Rpb24gcmUobix0LGUpe3NjLmxhc3RJbmRleD0wO3ZhciByPXNjLmV4ZWModC5zdWJzdHJpbmco
ZSxlKzIpKTtyZXR1cm4gcj8obi5TPStyWzBdLGUrclswXS5sZW5ndGgpOi0xfWZ1bmN0aW9uIHVl
KG4sdCxlKXtzYy5sYXN0SW5kZXg9MDt2YXIgcj1zYy5leGVjKHQuc3Vic3RyaW5nKGUsZSszKSk7
cmV0dXJuIHI/KG4uTD0rclswXSxlK3JbMF0ubGVuZ3RoKTotMX1mdW5jdGlvbiBpZShuKXt2YXIg
dD1uLmdldFRpbWV6b25lT2Zmc2V0KCksZT10PjA/Ii0iOiIrIixyPX5+KGZhKHQpLzYwKSx1PWZh
KHQpJTYwO3JldHVybiBlK0l0KHIsIjAiLDIpK0l0KHUsIjAiLDIpfWZ1bmN0aW9uIG9lKG4sdCxl
KXtsYy5sYXN0SW5kZXg9MDt2YXIgcj1sYy5leGVjKHQuc3Vic3RyaW5nKGUsZSsxKSk7cmV0dXJu
IHI/ZStyWzBdLmxlbmd0aDotMX1mdW5jdGlvbiBhZShuKXtmb3IodmFyIHQ9bi5sZW5ndGgsZT0t
MTsrK2U8dDspbltlXVswXT10aGlzKG5bZV1bMF0pO3JldHVybiBmdW5jdGlvbih0KXtmb3IodmFy
IGU9MCxyPW5bZV07IXJbMV0odCk7KXI9blsrK2VdO3JldHVybiByWzBdKHQpfX1mdW5jdGlvbiBj
ZSgpe31mdW5jdGlvbiBzZShuLHQsZSl7dmFyIHI9ZS5zPW4rdCx1PXItbixpPXItdTtlLnQ9bi1p
Kyh0LXUpfWZ1bmN0aW9uIGxlKG4sdCl7biYmcGMuaGFzT3duUHJvcGVydHkobi50eXBlKSYmcGNb
bi50eXBlXShuLHQpfWZ1bmN0aW9uIGZlKG4sdCxlKXt2YXIgcix1PS0xLGk9bi5sZW5ndGgtZTtm
b3IodC5saW5lU3RhcnQoKTsrK3U8aTspcj1uW3VdLHQucG9pbnQoclswXSxyWzFdLHJbMl0pO3Qu
bGluZUVuZCgpfWZ1bmN0aW9uIGhlKG4sdCl7dmFyIGU9LTEscj1uLmxlbmd0aDtmb3IodC5wb2x5
Z29uU3RhcnQoKTsrK2U8cjspZmUobltlXSx0LDEpO3QucG9seWdvbkVuZCgpfWZ1bmN0aW9uIGdl
KCl7ZnVuY3Rpb24gbihuLHQpe24qPXphLHQ9dCp6YS8yK0NhLzQ7dmFyIGU9bi1yLG89ZT49MD8x
Oi0xLGE9byplLGM9TWF0aC5jb3ModCkscz1NYXRoLnNpbih0KSxsPWkqcyxmPXUqYytsKk1hdGgu
Y29zKGEpLGg9bCpvKk1hdGguc2luKGEpO2RjLmFkZChNYXRoLmF0YW4yKGgsZikpLHI9bix1PWMs
aT1zfXZhciB0LGUscix1LGk7bWMucG9pbnQ9ZnVuY3Rpb24obyxhKXttYy5wb2ludD1uLHI9KHQ9
bykqemEsdT1NYXRoLmNvcyhhPShlPWEpKnphLzIrQ2EvNCksaT1NYXRoLnNpbihhKX0sbWMubGlu
ZUVuZD1mdW5jdGlvbigpe24odCxlKX19ZnVuY3Rpb24gcGUobil7dmFyIHQ9blswXSxlPW5bMV0s
cj1NYXRoLmNvcyhlKTtyZXR1cm5bcipNYXRoLmNvcyh0KSxyKk1hdGguc2luKHQpLE1hdGguc2lu
KGUpXX1mdW5jdGlvbiB2ZShuLHQpe3JldHVybiBuWzBdKnRbMF0rblsxXSp0WzFdK25bMl0qdFsy
XX1mdW5jdGlvbiBkZShuLHQpe3JldHVybltuWzFdKnRbMl0tblsyXSp0WzFdLG5bMl0qdFswXS1u
WzBdKnRbMl0sblswXSp0WzFdLW5bMV0qdFswXV19ZnVuY3Rpb24gbWUobix0KXtuWzBdKz10WzBd
LG5bMV0rPXRbMV0sblsyXSs9dFsyXX1mdW5jdGlvbiB5ZShuLHQpe3JldHVybltuWzBdKnQsblsx
XSp0LG5bMl0qdF19ZnVuY3Rpb24geGUobil7dmFyIHQ9TWF0aC5zcXJ0KG5bMF0qblswXStuWzFd
Km5bMV0rblsyXSpuWzJdKTtuWzBdLz10LG5bMV0vPXQsblsyXS89dH1mdW5jdGlvbiBNZShuKXty
ZXR1cm5bTWF0aC5hdGFuMihuWzFdLG5bMF0pLEcoblsyXSldfWZ1bmN0aW9uIF9lKG4sdCl7cmV0
dXJuIGZhKG5bMF0tdFswXSk8VGEmJmZhKG5bMV0tdFsxXSk8VGF9ZnVuY3Rpb24gYmUobix0KXtu
Kj16YTt2YXIgZT1NYXRoLmNvcyh0Kj16YSk7d2UoZSpNYXRoLmNvcyhuKSxlKk1hdGguc2luKG4p
LE1hdGguc2luKHQpKX1mdW5jdGlvbiB3ZShuLHQsZSl7Kyt5YyxNYys9KG4tTWMpL3ljLF9jKz0o
dC1fYykveWMsYmMrPShlLWJjKS95Y31mdW5jdGlvbiBTZSgpe2Z1bmN0aW9uIG4obix1KXtuKj16
YTt2YXIgaT1NYXRoLmNvcyh1Kj16YSksbz1pKk1hdGguY29zKG4pLGE9aSpNYXRoLnNpbihuKSxj
PU1hdGguc2luKHUpLHM9TWF0aC5hdGFuMihNYXRoLnNxcnQoKHM9ZSpjLXIqYSkqcysocz1yKm8t
dCpjKSpzKyhzPXQqYS1lKm8pKnMpLHQqbytlKmErcipjKTt4Yys9cyx3Yys9cyoodCsodD1vKSks
U2MrPXMqKGUrKGU9YSkpLGtjKz1zKihyKyhyPWMpKSx3ZSh0LGUscil9dmFyIHQsZSxyO05jLnBv
aW50PWZ1bmN0aW9uKHUsaSl7dSo9emE7dmFyIG89TWF0aC5jb3MoaSo9emEpO3Q9bypNYXRoLmNv
cyh1KSxlPW8qTWF0aC5zaW4odSkscj1NYXRoLnNpbihpKSxOYy5wb2ludD1uLHdlKHQsZSxyKX19
ZnVuY3Rpb24ga2UoKXtOYy5wb2ludD1iZX1mdW5jdGlvbiBFZSgpe2Z1bmN0aW9uIG4obix0KXtu
Kj16YTt2YXIgZT1NYXRoLmNvcyh0Kj16YSksbz1lKk1hdGguY29zKG4pLGE9ZSpNYXRoLnNpbihu
KSxjPU1hdGguc2luKHQpLHM9dSpjLWkqYSxsPWkqby1yKmMsZj1yKmEtdSpvLGg9TWF0aC5zcXJ0
KHMqcytsKmwrZipmKSxnPXIqbyt1KmEraSpjLHA9aCYmLVcoZykvaCx2PU1hdGguYXRhbjIoaCxn
KTtFYys9cCpzLEFjKz1wKmwsQ2MrPXAqZix4Yys9dix3Yys9dioocisocj1vKSksU2MrPXYqKHUr
KHU9YSkpLGtjKz12KihpKyhpPWMpKSx3ZShyLHUsaSl9dmFyIHQsZSxyLHUsaTtOYy5wb2ludD1m
dW5jdGlvbihvLGEpe3Q9byxlPWEsTmMucG9pbnQ9bixvKj16YTt2YXIgYz1NYXRoLmNvcyhhKj16
YSk7cj1jKk1hdGguY29zKG8pLHU9YypNYXRoLnNpbihvKSxpPU1hdGguc2luKGEpLHdlKHIsdSxp
KX0sTmMubGluZUVuZD1mdW5jdGlvbigpe24odCxlKSxOYy5saW5lRW5kPWtlLE5jLnBvaW50PWJl
fX1mdW5jdGlvbiBBZSgpe3JldHVybiEwfWZ1bmN0aW9uIENlKG4sdCxlLHIsdSl7dmFyIGk9W10s
bz1bXTtpZihuLmZvckVhY2goZnVuY3Rpb24obil7aWYoISgodD1uLmxlbmd0aC0xKTw9MCkpe3Zh
ciB0LGU9blswXSxyPW5bdF07aWYoX2UoZSxyKSl7dS5saW5lU3RhcnQoKTtmb3IodmFyIGE9MDt0
PmE7KythKXUucG9pbnQoKGU9blthXSlbMF0sZVsxXSk7cmV0dXJuIHUubGluZUVuZCgpLHZvaWQg
MH12YXIgYz1uZXcgTGUoZSxuLG51bGwsITApLHM9bmV3IExlKGUsbnVsbCxjLCExKTtjLm89cyxp
LnB1c2goYyksby5wdXNoKHMpLGM9bmV3IExlKHIsbixudWxsLCExKSxzPW5ldyBMZShyLG51bGws
YywhMCksYy5vPXMsaS5wdXNoKGMpLG8ucHVzaChzKX19KSxvLnNvcnQodCksTmUoaSksTmUobyks
aS5sZW5ndGgpe2Zvcih2YXIgYT0wLGM9ZSxzPW8ubGVuZ3RoO3M+YTsrK2Epb1thXS5lPWM9IWM7
Zm9yKHZhciBsLGYsaD1pWzBdOzspe2Zvcih2YXIgZz1oLHA9ITA7Zy52OylpZigoZz1nLm4pPT09
aClyZXR1cm47bD1nLnosdS5saW5lU3RhcnQoKTtkb3tpZihnLnY9Zy5vLnY9ITAsZy5lKXtpZihw
KWZvcih2YXIgYT0wLHM9bC5sZW5ndGg7cz5hOysrYSl1LnBvaW50KChmPWxbYV0pWzBdLGZbMV0p
O2Vsc2UgcihnLngsZy5uLngsMSx1KTtnPWcubn1lbHNle2lmKHApe2w9Zy5wLno7Zm9yKHZhciBh
PWwubGVuZ3RoLTE7YT49MDstLWEpdS5wb2ludCgoZj1sW2FdKVswXSxmWzFdKX1lbHNlIHIoZy54
LGcucC54LC0xLHUpO2c9Zy5wfWc9Zy5vLGw9Zy56LHA9IXB9d2hpbGUoIWcudik7dS5saW5lRW5k
KCl9fX1mdW5jdGlvbiBOZShuKXtpZih0PW4ubGVuZ3RoKXtmb3IodmFyIHQsZSxyPTAsdT1uWzBd
Oysrcjx0Oyl1Lm49ZT1uW3JdLGUucD11LHU9ZTt1Lm49ZT1uWzBdLGUucD11fX1mdW5jdGlvbiBM
ZShuLHQsZSxyKXt0aGlzLng9bix0aGlzLno9dCx0aGlzLm89ZSx0aGlzLmU9cix0aGlzLnY9ITEs
dGhpcy5uPXRoaXMucD1udWxsfWZ1bmN0aW9uIFRlKG4sdCxlLHIpe3JldHVybiBmdW5jdGlvbih1
LGkpe2Z1bmN0aW9uIG8odCxlKXt2YXIgcj11KHQsZSk7bih0PXJbMF0sZT1yWzFdKSYmaS5wb2lu
dCh0LGUpfWZ1bmN0aW9uIGEobix0KXt2YXIgZT11KG4sdCk7ZC5wb2ludChlWzBdLGVbMV0pfWZ1
bmN0aW9uIGMoKXt5LnBvaW50PWEsZC5saW5lU3RhcnQoKX1mdW5jdGlvbiBzKCl7eS5wb2ludD1v
LGQubGluZUVuZCgpfWZ1bmN0aW9uIGwobix0KXt2LnB1c2goW24sdF0pO3ZhciBlPXUobix0KTtN
LnBvaW50KGVbMF0sZVsxXSl9ZnVuY3Rpb24gZigpe00ubGluZVN0YXJ0KCksdj1bXX1mdW5jdGlv
biBoKCl7bCh2WzBdWzBdLHZbMF1bMV0pLE0ubGluZUVuZCgpO3ZhciBuLHQ9TS5jbGVhbigpLGU9
eC5idWZmZXIoKSxyPWUubGVuZ3RoO2lmKHYucG9wKCkscC5wdXNoKHYpLHY9bnVsbCxyKWlmKDEm
dCl7bj1lWzBdO3ZhciB1LHI9bi5sZW5ndGgtMSxvPS0xO2lmKHI+MCl7Zm9yKF98fChpLnBvbHln
b25TdGFydCgpLF89ITApLGkubGluZVN0YXJ0KCk7KytvPHI7KWkucG9pbnQoKHU9bltvXSlbMF0s
dVsxXSk7aS5saW5lRW5kKCl9fWVsc2Ugcj4xJiYyJnQmJmUucHVzaChlLnBvcCgpLmNvbmNhdChl
LnNoaWZ0KCkpKSxnLnB1c2goZS5maWx0ZXIocWUpKX12YXIgZyxwLHYsZD10KGkpLG09dS5pbnZl
cnQoclswXSxyWzFdKSx5PXtwb2ludDpvLGxpbmVTdGFydDpjLGxpbmVFbmQ6cyxwb2x5Z29uU3Rh
cnQ6ZnVuY3Rpb24oKXt5LnBvaW50PWwseS5saW5lU3RhcnQ9Zix5LmxpbmVFbmQ9aCxnPVtdLHA9
W119LHBvbHlnb25FbmQ6ZnVuY3Rpb24oKXt5LnBvaW50PW8seS5saW5lU3RhcnQ9Yyx5LmxpbmVF
bmQ9cyxnPUdvLm1lcmdlKGcpO3ZhciBuPURlKG0scCk7Zy5sZW5ndGg/KF98fChpLnBvbHlnb25T
dGFydCgpLF89ITApLENlKGcsUmUsbixlLGkpKTpuJiYoX3x8KGkucG9seWdvblN0YXJ0KCksXz0h
MCksaS5saW5lU3RhcnQoKSxlKG51bGwsbnVsbCwxLGkpLGkubGluZUVuZCgpKSxfJiYoaS5wb2x5
Z29uRW5kKCksXz0hMSksZz1wPW51bGx9LHNwaGVyZTpmdW5jdGlvbigpe2kucG9seWdvblN0YXJ0
KCksaS5saW5lU3RhcnQoKSxlKG51bGwsbnVsbCwxLGkpLGkubGluZUVuZCgpLGkucG9seWdvbkVu
ZCgpfX0seD16ZSgpLE09dCh4KSxfPSExO3JldHVybiB5fX1mdW5jdGlvbiBxZShuKXtyZXR1cm4g
bi5sZW5ndGg+MX1mdW5jdGlvbiB6ZSgpe3ZhciBuLHQ9W107cmV0dXJue2xpbmVTdGFydDpmdW5j
dGlvbigpe3QucHVzaChuPVtdKX0scG9pbnQ6ZnVuY3Rpb24odCxlKXtuLnB1c2goW3QsZV0pfSxs
aW5lRW5kOnYsYnVmZmVyOmZ1bmN0aW9uKCl7dmFyIGU9dDtyZXR1cm4gdD1bXSxuPW51bGwsZX0s
cmVqb2luOmZ1bmN0aW9uKCl7dC5sZW5ndGg+MSYmdC5wdXNoKHQucG9wKCkuY29uY2F0KHQuc2hp
ZnQoKSkpfX19ZnVuY3Rpb24gUmUobix0KXtyZXR1cm4oKG49bi54KVswXTwwP25bMV0tTGEtVGE6
TGEtblsxXSktKCh0PXQueClbMF08MD90WzFdLUxhLVRhOkxhLXRbMV0pfWZ1bmN0aW9uIERlKG4s
dCl7dmFyIGU9blswXSxyPW5bMV0sdT1bTWF0aC5zaW4oZSksLU1hdGguY29zKGUpLDBdLGk9MCxv
PTA7ZGMucmVzZXQoKTtmb3IodmFyIGE9MCxjPXQubGVuZ3RoO2M+YTsrK2Epe3ZhciBzPXRbYV0s
bD1zLmxlbmd0aDtpZihsKWZvcih2YXIgZj1zWzBdLGg9ZlswXSxnPWZbMV0vMitDYS80LHA9TWF0
aC5zaW4oZyksdj1NYXRoLmNvcyhnKSxkPTE7Oyl7ZD09PWwmJihkPTApLG49c1tkXTt2YXIgbT1u
WzBdLHk9blsxXS8yK0NhLzQseD1NYXRoLnNpbih5KSxNPU1hdGguY29zKHkpLF89bS1oLGI9Xz49
MD8xOi0xLHc9YipfLFM9dz5DYSxrPXAqeDtpZihkYy5hZGQoTWF0aC5hdGFuMihrKmIqTWF0aC5z
aW4odyksdipNK2sqTWF0aC5jb3ModykpKSxpKz1TP18rYipOYTpfLFNeaD49ZV5tPj1lKXt2YXIg
RT1kZShwZShmKSxwZShuKSk7eGUoRSk7dmFyIEE9ZGUodSxFKTt4ZShBKTt2YXIgQz0oU15fPj0w
Py0xOjEpKkcoQVsyXSk7KHI+Q3x8cj09PUMmJihFWzBdfHxFWzFdKSkmJihvKz1TXl8+PTA/MTot
MSl9aWYoIWQrKylicmVhaztoPW0scD14LHY9TSxmPW59fXJldHVybigtVGE+aXx8VGE+aSYmMD5k
YyleMSZvfWZ1bmN0aW9uIFBlKG4pe3ZhciB0LGU9MC8wLHI9MC8wLHU9MC8wO3JldHVybntsaW5l
U3RhcnQ6ZnVuY3Rpb24oKXtuLmxpbmVTdGFydCgpLHQ9MX0scG9pbnQ6ZnVuY3Rpb24oaSxvKXt2
YXIgYT1pPjA/Q2E6LUNhLGM9ZmEoaS1lKTtmYShjLUNhKTxUYT8obi5wb2ludChlLHI9KHIrbykv
Mj4wP0xhOi1MYSksbi5wb2ludCh1LHIpLG4ubGluZUVuZCgpLG4ubGluZVN0YXJ0KCksbi5wb2lu
dChhLHIpLG4ucG9pbnQoaSxyKSx0PTApOnUhPT1hJiZjPj1DYSYmKGZhKGUtdSk8VGEmJihlLT11
KlRhKSxmYShpLWEpPFRhJiYoaS09YSpUYSkscj1VZShlLHIsaSxvKSxuLnBvaW50KHUsciksbi5s
aW5lRW5kKCksbi5saW5lU3RhcnQoKSxuLnBvaW50KGEsciksdD0wKSxuLnBvaW50KGU9aSxyPW8p
LHU9YX0sbGluZUVuZDpmdW5jdGlvbigpe24ubGluZUVuZCgpLGU9cj0wLzB9LGNsZWFuOmZ1bmN0
aW9uKCl7cmV0dXJuIDItdH19fWZ1bmN0aW9uIFVlKG4sdCxlLHIpe3ZhciB1LGksbz1NYXRoLnNp
bihuLWUpO3JldHVybiBmYShvKT5UYT9NYXRoLmF0YW4oKE1hdGguc2luKHQpKihpPU1hdGguY29z
KHIpKSpNYXRoLnNpbihlKS1NYXRoLnNpbihyKSoodT1NYXRoLmNvcyh0KSkqTWF0aC5zaW4obikp
Lyh1KmkqbykpOih0K3IpLzJ9ZnVuY3Rpb24gamUobix0LGUscil7dmFyIHU7aWYobnVsbD09bil1
PWUqTGEsci5wb2ludCgtQ2EsdSksci5wb2ludCgwLHUpLHIucG9pbnQoQ2EsdSksci5wb2ludChD
YSwwKSxyLnBvaW50KENhLC11KSxyLnBvaW50KDAsLXUpLHIucG9pbnQoLUNhLC11KSxyLnBvaW50
KC1DYSwwKSxyLnBvaW50KC1DYSx1KTtlbHNlIGlmKGZhKG5bMF0tdFswXSk+VGEpe3ZhciBpPW5b
MF08dFswXT9DYTotQ2E7dT1lKmkvMixyLnBvaW50KC1pLHUpLHIucG9pbnQoMCx1KSxyLnBvaW50
KGksdSl9ZWxzZSByLnBvaW50KHRbMF0sdFsxXSl9ZnVuY3Rpb24gSGUobil7ZnVuY3Rpb24gdChu
LHQpe3JldHVybiBNYXRoLmNvcyhuKSpNYXRoLmNvcyh0KT5pfWZ1bmN0aW9uIGUobil7dmFyIGUs
aSxjLHMsbDtyZXR1cm57bGluZVN0YXJ0OmZ1bmN0aW9uKCl7cz1jPSExLGw9MX0scG9pbnQ6ZnVu
Y3Rpb24oZixoKXt2YXIgZyxwPVtmLGhdLHY9dChmLGgpLGQ9bz92PzA6dShmLGgpOnY/dShmKygw
PmY/Q2E6LUNhKSxoKTowO2lmKCFlJiYocz1jPXYpJiZuLmxpbmVTdGFydCgpLHYhPT1jJiYoZz1y
KGUscCksKF9lKGUsZyl8fF9lKHAsZykpJiYocFswXSs9VGEscFsxXSs9VGEsdj10KHBbMF0scFsx
XSkpKSx2IT09YylsPTAsdj8obi5saW5lU3RhcnQoKSxnPXIocCxlKSxuLnBvaW50KGdbMF0sZ1sx
XSkpOihnPXIoZSxwKSxuLnBvaW50KGdbMF0sZ1sxXSksbi5saW5lRW5kKCkpLGU9ZztlbHNlIGlm
KGEmJmUmJm9edil7dmFyIG07ZCZpfHwhKG09cihwLGUsITApKXx8KGw9MCxvPyhuLmxpbmVTdGFy
dCgpLG4ucG9pbnQobVswXVswXSxtWzBdWzFdKSxuLnBvaW50KG1bMV1bMF0sbVsxXVsxXSksbi5s
aW5lRW5kKCkpOihuLnBvaW50KG1bMV1bMF0sbVsxXVsxXSksbi5saW5lRW5kKCksbi5saW5lU3Rh
cnQoKSxuLnBvaW50KG1bMF1bMF0sbVswXVsxXSkpKX0hdnx8ZSYmX2UoZSxwKXx8bi5wb2ludChw
WzBdLHBbMV0pLGU9cCxjPXYsaT1kfSxsaW5lRW5kOmZ1bmN0aW9uKCl7YyYmbi5saW5lRW5kKCks
ZT1udWxsfSxjbGVhbjpmdW5jdGlvbigpe3JldHVybiBsfChzJiZjKTw8MX19fWZ1bmN0aW9uIHIo
bix0LGUpe3ZhciByPXBlKG4pLHU9cGUodCksbz1bMSwwLDBdLGE9ZGUocix1KSxjPXZlKGEsYSks
cz1hWzBdLGw9Yy1zKnM7aWYoIWwpcmV0dXJuIWUmJm47dmFyIGY9aSpjL2wsaD0taSpzL2wsZz1k
ZShvLGEpLHA9eWUobyxmKSx2PXllKGEsaCk7bWUocCx2KTt2YXIgZD1nLG09dmUocCxkKSx5PXZl
KGQsZCkseD1tKm0teSoodmUocCxwKS0xKTtpZighKDA+eCkpe3ZhciBNPU1hdGguc3FydCh4KSxf
PXllKGQsKC1tLU0pL3kpO2lmKG1lKF8scCksXz1NZShfKSwhZSlyZXR1cm4gXzt2YXIgYix3PW5b
MF0sUz10WzBdLGs9blsxXSxFPXRbMV07dz5TJiYoYj13LHc9UyxTPWIpO3ZhciBBPVMtdyxDPWZh
KEEtQ2EpPFRhLE49Q3x8VGE+QTtpZighQyYmaz5FJiYoYj1rLGs9RSxFPWIpLE4/Qz9rK0U+MF5f
WzFdPChmYShfWzBdLXcpPFRhP2s6RSk6azw9X1sxXSYmX1sxXTw9RTpBPkNhXih3PD1fWzBdJiZf
WzBdPD1TKSl7dmFyIEw9eWUoZCwoLW0rTSkveSk7cmV0dXJuIG1lKEwscCksW18sTWUoTCldfX19
ZnVuY3Rpb24gdSh0LGUpe3ZhciByPW8/bjpDYS1uLHU9MDtyZXR1cm4tcj50P3V8PTE6dD5yJiYo
dXw9MiksLXI+ZT91fD00OmU+ciYmKHV8PTgpLHV9dmFyIGk9TWF0aC5jb3Mobiksbz1pPjAsYT1m
YShpKT5UYSxjPWdyKG4sNip6YSk7cmV0dXJuIFRlKHQsZSxjLG8/WzAsLW5dOlstQ2Esbi1DYV0p
fWZ1bmN0aW9uIEZlKG4sdCxlLHIpe3JldHVybiBmdW5jdGlvbih1KXt2YXIgaSxvPXUuYSxhPXUu
YixjPW8ueCxzPW8ueSxsPWEueCxmPWEueSxoPTAsZz0xLHA9bC1jLHY9Zi1zO2lmKGk9bi1jLHB8
fCEoaT4wKSl7aWYoaS89cCwwPnApe2lmKGg+aSlyZXR1cm47Zz5pJiYoZz1pKX1lbHNlIGlmKHA+
MCl7aWYoaT5nKXJldHVybjtpPmgmJihoPWkpfWlmKGk9ZS1jLHB8fCEoMD5pKSl7aWYoaS89cCww
PnApe2lmKGk+ZylyZXR1cm47aT5oJiYoaD1pKX1lbHNlIGlmKHA+MCl7aWYoaD5pKXJldHVybjtn
PmkmJihnPWkpfWlmKGk9dC1zLHZ8fCEoaT4wKSl7aWYoaS89diwwPnYpe2lmKGg+aSlyZXR1cm47
Zz5pJiYoZz1pKX1lbHNlIGlmKHY+MCl7aWYoaT5nKXJldHVybjtpPmgmJihoPWkpfWlmKGk9ci1z
LHZ8fCEoMD5pKSl7aWYoaS89diwwPnYpe2lmKGk+ZylyZXR1cm47aT5oJiYoaD1pKX1lbHNlIGlm
KHY+MCl7aWYoaD5pKXJldHVybjtnPmkmJihnPWkpfXJldHVybiBoPjAmJih1LmE9e3g6YytoKnAs
eTpzK2gqdn0pLDE+ZyYmKHUuYj17eDpjK2cqcCx5OnMrZyp2fSksdX19fX19fWZ1bmN0aW9uIE9l
KG4sdCxlLHIpe2Z1bmN0aW9uIHUocix1KXtyZXR1cm4gZmEoclswXS1uKTxUYT91PjA/MDozOmZh
KHJbMF0tZSk8VGE/dT4wPzI6MTpmYShyWzFdLXQpPFRhP3U+MD8xOjA6dT4wPzM6Mn1mdW5jdGlv
biBpKG4sdCl7cmV0dXJuIG8obi54LHQueCl9ZnVuY3Rpb24gbyhuLHQpe3ZhciBlPXUobiwxKSxy
PXUodCwxKTtyZXR1cm4gZSE9PXI/ZS1yOjA9PT1lP3RbMV0tblsxXToxPT09ZT9uWzBdLXRbMF06
Mj09PWU/blsxXS10WzFdOnRbMF0tblswXX1yZXR1cm4gZnVuY3Rpb24oYSl7ZnVuY3Rpb24gYyhu
KXtmb3IodmFyIHQ9MCxlPWQubGVuZ3RoLHI9blsxXSx1PTA7ZT51OysrdSlmb3IodmFyIGksbz0x
LGE9ZFt1XSxjPWEubGVuZ3RoLHM9YVswXTtjPm87KytvKWk9YVtvXSxzWzFdPD1yP2lbMV0+ciYm
SihzLGksbik+MCYmKyt0OmlbMV08PXImJkoocyxpLG4pPDAmJi0tdCxzPWk7cmV0dXJuIDAhPT10
fWZ1bmN0aW9uIHMoaSxhLGMscyl7dmFyIGw9MCxmPTA7aWYobnVsbD09aXx8KGw9dShpLGMpKSE9
PShmPXUoYSxjKSl8fG8oaSxhKTwwXmM+MCl7ZG8gcy5wb2ludCgwPT09bHx8Mz09PWw/bjplLGw+
MT9yOnQpO3doaWxlKChsPShsK2MrNCklNCkhPT1mKX1lbHNlIHMucG9pbnQoYVswXSxhWzFdKX1m
dW5jdGlvbiBsKHUsaSl7cmV0dXJuIHU+PW4mJmU+PXUmJmk+PXQmJnI+PWl9ZnVuY3Rpb24gZihu
LHQpe2wobix0KSYmYS5wb2ludChuLHQpfWZ1bmN0aW9uIGgoKXtOLnBvaW50PXAsZCYmZC5wdXNo
KG09W10pLFM9ITAsdz0hMSxfPWI9MC8wfWZ1bmN0aW9uIGcoKXt2JiYocCh5LHgpLE0mJncmJkEu
cmVqb2luKCksdi5wdXNoKEEuYnVmZmVyKCkpKSxOLnBvaW50PWYsdyYmYS5saW5lRW5kKCl9ZnVu
Y3Rpb24gcChuLHQpe249TWF0aC5tYXgoLVRjLE1hdGgubWluKFRjLG4pKSx0PU1hdGgubWF4KC1U
YyxNYXRoLm1pbihUYyx0KSk7dmFyIGU9bChuLHQpO2lmKGQmJm0ucHVzaChbbix0XSksUyl5PW4s
eD10LE09ZSxTPSExLGUmJihhLmxpbmVTdGFydCgpLGEucG9pbnQobix0KSk7ZWxzZSBpZihlJiZ3
KWEucG9pbnQobix0KTtlbHNle3ZhciByPXthOnt4Ol8seTpifSxiOnt4Om4seTp0fX07QyhyKT8o
d3x8KGEubGluZVN0YXJ0KCksYS5wb2ludChyLmEueCxyLmEueSkpLGEucG9pbnQoci5iLngsci5i
LnkpLGV8fGEubGluZUVuZCgpLGs9ITEpOmUmJihhLmxpbmVTdGFydCgpLGEucG9pbnQobix0KSxr
PSExKX1fPW4sYj10LHc9ZX12YXIgdixkLG0seSx4LE0sXyxiLHcsUyxrLEU9YSxBPXplKCksQz1G
ZShuLHQsZSxyKSxOPXtwb2ludDpmLGxpbmVTdGFydDpoLGxpbmVFbmQ6Zyxwb2x5Z29uU3RhcnQ6
ZnVuY3Rpb24oKXthPUEsdj1bXSxkPVtdLGs9ITB9LHBvbHlnb25FbmQ6ZnVuY3Rpb24oKXthPUUs
dj1Hby5tZXJnZSh2KTt2YXIgdD1jKFtuLHJdKSxlPWsmJnQsdT12Lmxlbmd0aDsoZXx8dSkmJihh
LnBvbHlnb25TdGFydCgpLGUmJihhLmxpbmVTdGFydCgpLHMobnVsbCxudWxsLDEsYSksYS5saW5l
RW5kKCkpLHUmJkNlKHYsaSx0LHMsYSksYS5wb2x5Z29uRW5kKCkpLHY9ZD1tPW51bGx9fTtyZXR1
cm4gTn19ZnVuY3Rpb24gSWUobix0KXtmdW5jdGlvbiBlKGUscil7cmV0dXJuIGU9bihlLHIpLHQo
ZVswXSxlWzFdKX1yZXR1cm4gbi5pbnZlcnQmJnQuaW52ZXJ0JiYoZS5pbnZlcnQ9ZnVuY3Rpb24o
ZSxyKXtyZXR1cm4gZT10LmludmVydChlLHIpLGUmJm4uaW52ZXJ0KGVbMF0sZVsxXSl9KSxlfWZ1
bmN0aW9uIFllKG4pe3ZhciB0PTAsZT1DYS8zLHI9aXIobiksdT1yKHQsZSk7cmV0dXJuIHUucGFy
YWxsZWxzPWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoP3IodD1uWzBdKkNhLzE4
MCxlPW5bMV0qQ2EvMTgwKTpbMTgwKih0L0NhKSwxODAqKGUvQ2EpXX0sdX1mdW5jdGlvbiBaZShu
LHQpe2Z1bmN0aW9uIGUobix0KXt2YXIgZT1NYXRoLnNxcnQoaS0yKnUqTWF0aC5zaW4odCkpL3U7
cmV0dXJuW2UqTWF0aC5zaW4obio9dSksby1lKk1hdGguY29zKG4pXX12YXIgcj1NYXRoLnNpbihu
KSx1PShyK01hdGguc2luKHQpKS8yLGk9MStyKigyKnUtciksbz1NYXRoLnNxcnQoaSkvdTtyZXR1
cm4gZS5pbnZlcnQ9ZnVuY3Rpb24obix0KXt2YXIgZT1vLXQ7cmV0dXJuW01hdGguYXRhbjIobixl
KS91LEcoKGktKG4qbitlKmUpKnUqdSkvKDIqdSkpXX0sZX1mdW5jdGlvbiBWZSgpe2Z1bmN0aW9u
IG4obix0KXt6Yys9dSpuLXIqdCxyPW4sdT10fXZhciB0LGUscix1O2pjLnBvaW50PWZ1bmN0aW9u
KGksbyl7amMucG9pbnQ9bix0PXI9aSxlPXU9b30samMubGluZUVuZD1mdW5jdGlvbigpe24odCxl
KX19ZnVuY3Rpb24gJGUobix0KXtSYz5uJiYoUmM9biksbj5QYyYmKFBjPW4pLERjPnQmJihEYz10
KSx0PlVjJiYoVWM9dCl9ZnVuY3Rpb24gWGUoKXtmdW5jdGlvbiBuKG4sdCl7by5wdXNoKCJNIixu
LCIsIix0LGkpfWZ1bmN0aW9uIHQobix0KXtvLnB1c2goIk0iLG4sIiwiLHQpLGEucG9pbnQ9ZX1m
dW5jdGlvbiBlKG4sdCl7by5wdXNoKCJMIixuLCIsIix0KX1mdW5jdGlvbiByKCl7YS5wb2ludD1u
fWZ1bmN0aW9uIHUoKXtvLnB1c2goIloiKX12YXIgaT1CZSg0LjUpLG89W10sYT17cG9pbnQ6bixs
aW5lU3RhcnQ6ZnVuY3Rpb24oKXthLnBvaW50PXR9LGxpbmVFbmQ6cixwb2x5Z29uU3RhcnQ6ZnVu
Y3Rpb24oKXthLmxpbmVFbmQ9dX0scG9seWdvbkVuZDpmdW5jdGlvbigpe2EubGluZUVuZD1yLGEu
cG9pbnQ9bn0scG9pbnRSYWRpdXM6ZnVuY3Rpb24obil7cmV0dXJuIGk9QmUobiksYX0scmVzdWx0
OmZ1bmN0aW9uKCl7aWYoby5sZW5ndGgpe3ZhciBuPW8uam9pbigiIik7cmV0dXJuIG89W10sbn19
fTtyZXR1cm4gYX1mdW5jdGlvbiBCZShuKXtyZXR1cm4ibTAsIituKyJhIituKyIsIituKyIgMCAx
LDEgMCwiKy0yKm4rImEiK24rIiwiK24rIiAwIDEsMSAwLCIrMipuKyJ6In1mdW5jdGlvbiBKZShu
LHQpe01jKz1uLF9jKz10LCsrYmN9ZnVuY3Rpb24gV2UoKXtmdW5jdGlvbiBuKG4scil7dmFyIHU9
bi10LGk9ci1lLG89TWF0aC5zcXJ0KHUqdStpKmkpO3djKz1vKih0K24pLzIsU2MrPW8qKGUrcikv
MixrYys9byxKZSh0PW4sZT1yKX12YXIgdCxlO0ZjLnBvaW50PWZ1bmN0aW9uKHIsdSl7RmMucG9p
bnQ9bixKZSh0PXIsZT11KX19ZnVuY3Rpb24gR2UoKXtGYy5wb2ludD1KZX1mdW5jdGlvbiBLZSgp
e2Z1bmN0aW9uIG4obix0KXt2YXIgZT1uLXIsaT10LXUsbz1NYXRoLnNxcnQoZSplK2kqaSk7d2Mr
PW8qKHIrbikvMixTYys9byoodSt0KS8yLGtjKz1vLG89dSpuLXIqdCxFYys9byoocituKSxBYys9
byoodSt0KSxDYys9MypvLEplKHI9bix1PXQpfXZhciB0LGUscix1O0ZjLnBvaW50PWZ1bmN0aW9u
KGksbyl7RmMucG9pbnQ9bixKZSh0PXI9aSxlPXU9byl9LEZjLmxpbmVFbmQ9ZnVuY3Rpb24oKXtu
KHQsZSl9fWZ1bmN0aW9uIFFlKG4pe2Z1bmN0aW9uIHQodCxlKXtuLm1vdmVUbyh0LGUpLG4uYXJj
KHQsZSxvLDAsTmEpfWZ1bmN0aW9uIGUodCxlKXtuLm1vdmVUbyh0LGUpLGEucG9pbnQ9cn1mdW5j
dGlvbiByKHQsZSl7bi5saW5lVG8odCxlKX1mdW5jdGlvbiB1KCl7YS5wb2ludD10fWZ1bmN0aW9u
IGkoKXtuLmNsb3NlUGF0aCgpfXZhciBvPTQuNSxhPXtwb2ludDp0LGxpbmVTdGFydDpmdW5jdGlv
bigpe2EucG9pbnQ9ZX0sbGluZUVuZDp1LHBvbHlnb25TdGFydDpmdW5jdGlvbigpe2EubGluZUVu
ZD1pfSxwb2x5Z29uRW5kOmZ1bmN0aW9uKCl7YS5saW5lRW5kPXUsYS5wb2ludD10fSxwb2ludFJh
ZGl1czpmdW5jdGlvbihuKXtyZXR1cm4gbz1uLGF9LHJlc3VsdDp2fTtyZXR1cm4gYX1mdW5jdGlv
biBucihuKXtmdW5jdGlvbiB0KG4pe3JldHVybihhP3I6ZSkobil9ZnVuY3Rpb24gZSh0KXtyZXR1
cm4gcnIodCxmdW5jdGlvbihlLHIpe2U9bihlLHIpLHQucG9pbnQoZVswXSxlWzFdKX0pfWZ1bmN0
aW9uIHIodCl7ZnVuY3Rpb24gZShlLHIpe2U9bihlLHIpLHQucG9pbnQoZVswXSxlWzFdKX1mdW5j
dGlvbiByKCl7eD0wLzAsUy5wb2ludD1pLHQubGluZVN0YXJ0KCl9ZnVuY3Rpb24gaShlLHIpe3Zh
ciBpPXBlKFtlLHJdKSxvPW4oZSxyKTt1KHgsTSx5LF8sYix3LHg9b1swXSxNPW9bMV0seT1lLF89
aVswXSxiPWlbMV0sdz1pWzJdLGEsdCksdC5wb2ludCh4LE0pfWZ1bmN0aW9uIG8oKXtTLnBvaW50
PWUsdC5saW5lRW5kKCl9ZnVuY3Rpb24gYygpe3IoKSxTLnBvaW50PXMsUy5saW5lRW5kPWx9ZnVu
Y3Rpb24gcyhuLHQpe2koZj1uLGg9dCksZz14LHA9TSx2PV8sZD1iLG09dyxTLnBvaW50PWl9ZnVu
Y3Rpb24gbCgpe3UoeCxNLHksXyxiLHcsZyxwLGYsdixkLG0sYSx0KSxTLmxpbmVFbmQ9byxvKCl9
dmFyIGYsaCxnLHAsdixkLG0seSx4LE0sXyxiLHcsUz17cG9pbnQ6ZSxsaW5lU3RhcnQ6cixsaW5l
RW5kOm8scG9seWdvblN0YXJ0OmZ1bmN0aW9uKCl7dC5wb2x5Z29uU3RhcnQoKSxTLmxpbmVTdGFy
dD1jfSxwb2x5Z29uRW5kOmZ1bmN0aW9uKCl7dC5wb2x5Z29uRW5kKCksUy5saW5lU3RhcnQ9cn19
O3JldHVybiBTfWZ1bmN0aW9uIHUodCxlLHIsYSxjLHMsbCxmLGgsZyxwLHYsZCxtKXt2YXIgeT1s
LXQseD1mLWUsTT15KnkreCp4O2lmKE0+NCppJiZkLS0pe3ZhciBfPWErZyxiPWMrcCx3PXMrdixT
PU1hdGguc3FydChfKl8rYipiK3cqdyksaz1NYXRoLmFzaW4ody89UyksRT1mYShmYSh3KS0xKTxU
YXx8ZmEoci1oKTxUYT8ocitoKS8yOk1hdGguYXRhbjIoYixfKSxBPW4oRSxrKSxDPUFbMF0sTj1B
WzFdLEw9Qy10LFQ9Ti1lLHE9eCpMLXkqVDsocSpxL00+aXx8ZmEoKHkqTCt4KlQpL00tLjUpPi4z
fHxvPmEqZytjKnArcyp2KSYmKHUodCxlLHIsYSxjLHMsQyxOLEUsXy89UyxiLz1TLHcsZCxtKSxt
LnBvaW50KEMsTiksdShDLE4sRSxfLGIsdyxsLGYsaCxnLHAsdixkLG0pKX19dmFyIGk9LjUsbz1N
YXRoLmNvcygzMCp6YSksYT0xNjtyZXR1cm4gdC5wcmVjaXNpb249ZnVuY3Rpb24obil7cmV0dXJu
IGFyZ3VtZW50cy5sZW5ndGg/KGE9KGk9bipuKT4wJiYxNix0KTpNYXRoLnNxcnQoaSl9LHR9ZnVu
Y3Rpb24gdHIobil7dmFyIHQ9bnIoZnVuY3Rpb24odCxlKXtyZXR1cm4gbihbdCpSYSxlKlJhXSl9
KTtyZXR1cm4gZnVuY3Rpb24obil7cmV0dXJuIG9yKHQobikpfX1mdW5jdGlvbiBlcihuKXt0aGlz
LnN0cmVhbT1ufWZ1bmN0aW9uIHJyKG4sdCl7cmV0dXJue3BvaW50OnQsc3BoZXJlOmZ1bmN0aW9u
KCl7bi5zcGhlcmUoKX0sbGluZVN0YXJ0OmZ1bmN0aW9uKCl7bi5saW5lU3RhcnQoKX0sbGluZUVu
ZDpmdW5jdGlvbigpe24ubGluZUVuZCgpfSxwb2x5Z29uU3RhcnQ6ZnVuY3Rpb24oKXtuLnBvbHln
b25TdGFydCgpfSxwb2x5Z29uRW5kOmZ1bmN0aW9uKCl7bi5wb2x5Z29uRW5kKCl9fX1mdW5jdGlv
biB1cihuKXtyZXR1cm4gaXIoZnVuY3Rpb24oKXtyZXR1cm4gbn0pKCl9ZnVuY3Rpb24gaXIobil7
ZnVuY3Rpb24gdChuKXtyZXR1cm4gbj1hKG5bMF0qemEsblsxXSp6YSksW25bMF0qaCtjLHMtblsx
XSpoXX1mdW5jdGlvbiBlKG4pe3JldHVybiBuPWEuaW52ZXJ0KChuWzBdLWMpL2gsKHMtblsxXSkv
aCksbiYmW25bMF0qUmEsblsxXSpSYV19ZnVuY3Rpb24gcigpe2E9SWUobz1zcihtLHkseCksaSk7
dmFyIG49aSh2LGQpO3JldHVybiBjPWctblswXSpoLHM9cCtuWzFdKmgsdSgpCn1mdW5jdGlvbiB1
KCl7cmV0dXJuIGwmJihsLnZhbGlkPSExLGw9bnVsbCksdH12YXIgaSxvLGEsYyxzLGwsZj1ucihm
dW5jdGlvbihuLHQpe3JldHVybiBuPWkobix0KSxbblswXSpoK2Mscy1uWzFdKmhdfSksaD0xNTAs
Zz00ODAscD0yNTAsdj0wLGQ9MCxtPTAseT0wLHg9MCxNPUxjLF89QXQsYj1udWxsLHc9bnVsbDty
ZXR1cm4gdC5zdHJlYW09ZnVuY3Rpb24obil7cmV0dXJuIGwmJihsLnZhbGlkPSExKSxsPW9yKE0o
byxmKF8obikpKSksbC52YWxpZD0hMCxsfSx0LmNsaXBBbmdsZT1mdW5jdGlvbihuKXtyZXR1cm4g
YXJndW1lbnRzLmxlbmd0aD8oTT1udWxsPT1uPyhiPW4sTGMpOkhlKChiPStuKSp6YSksdSgpKTpi
fSx0LmNsaXBFeHRlbnQ9ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KHc9bixf
PW4/T2UoblswXVswXSxuWzBdWzFdLG5bMV1bMF0sblsxXVsxXSk6QXQsdSgpKTp3fSx0LnNjYWxl
PWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhoPStuLHIoKSk6aH0sdC50cmFu
c2xhdGU9ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KGc9K25bMF0scD0rblsx
XSxyKCkpOltnLHBdfSx0LmNlbnRlcj1mdW5jdGlvbihuKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0
aD8odj1uWzBdJTM2MCp6YSxkPW5bMV0lMzYwKnphLHIoKSk6W3YqUmEsZCpSYV19LHQucm90YXRl
PWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhtPW5bMF0lMzYwKnphLHk9blsx
XSUzNjAqemEseD1uLmxlbmd0aD4yP25bMl0lMzYwKnphOjAscigpKTpbbSpSYSx5KlJhLHgqUmFd
fSxHby5yZWJpbmQodCxmLCJwcmVjaXNpb24iKSxmdW5jdGlvbigpe3JldHVybiBpPW4uYXBwbHko
dGhpcyxhcmd1bWVudHMpLHQuaW52ZXJ0PWkuaW52ZXJ0JiZlLHIoKX19ZnVuY3Rpb24gb3Iobil7
cmV0dXJuIHJyKG4sZnVuY3Rpb24odCxlKXtuLnBvaW50KHQqemEsZSp6YSl9KX1mdW5jdGlvbiBh
cihuLHQpe3JldHVybltuLHRdfWZ1bmN0aW9uIGNyKG4sdCl7cmV0dXJuW24+Q2E/bi1OYTotQ2E+
bj9uK05hOm4sdF19ZnVuY3Rpb24gc3Iobix0LGUpe3JldHVybiBuP3R8fGU/SWUoZnIobiksaHIo
dCxlKSk6ZnIobik6dHx8ZT9ocih0LGUpOmNyfWZ1bmN0aW9uIGxyKG4pe3JldHVybiBmdW5jdGlv
bih0LGUpe3JldHVybiB0Kz1uLFt0PkNhP3QtTmE6LUNhPnQ/dCtOYTp0LGVdfX1mdW5jdGlvbiBm
cihuKXt2YXIgdD1scihuKTtyZXR1cm4gdC5pbnZlcnQ9bHIoLW4pLHR9ZnVuY3Rpb24gaHIobix0
KXtmdW5jdGlvbiBlKG4sdCl7dmFyIGU9TWF0aC5jb3ModCksYT1NYXRoLmNvcyhuKSplLGM9TWF0
aC5zaW4obikqZSxzPU1hdGguc2luKHQpLGw9cypyK2EqdTtyZXR1cm5bTWF0aC5hdGFuMihjKmkt
bCpvLGEqci1zKnUpLEcobCppK2MqbyldfXZhciByPU1hdGguY29zKG4pLHU9TWF0aC5zaW4obiks
aT1NYXRoLmNvcyh0KSxvPU1hdGguc2luKHQpO3JldHVybiBlLmludmVydD1mdW5jdGlvbihuLHQp
e3ZhciBlPU1hdGguY29zKHQpLGE9TWF0aC5jb3MobikqZSxjPU1hdGguc2luKG4pKmUscz1NYXRo
LnNpbih0KSxsPXMqaS1jKm87cmV0dXJuW01hdGguYXRhbjIoYyppK3MqbyxhKnIrbCp1KSxHKGwq
ci1hKnUpXX0sZX1mdW5jdGlvbiBncihuLHQpe3ZhciBlPU1hdGguY29zKG4pLHI9TWF0aC5zaW4o
bik7cmV0dXJuIGZ1bmN0aW9uKHUsaSxvLGEpe3ZhciBjPW8qdDtudWxsIT11Pyh1PXByKGUsdSks
aT1wcihlLGkpLChvPjA/aT51OnU+aSkmJih1Kz1vKk5hKSk6KHU9bitvKk5hLGk9bi0uNSpjKTtm
b3IodmFyIHMsbD11O28+MD9sPmk6aT5sO2wtPWMpYS5wb2ludCgocz1NZShbZSwtcipNYXRoLmNv
cyhsKSwtcipNYXRoLnNpbihsKV0pKVswXSxzWzFdKX19ZnVuY3Rpb24gcHIobix0KXt2YXIgZT1w
ZSh0KTtlWzBdLT1uLHhlKGUpO3ZhciByPVcoLWVbMV0pO3JldHVybigoLWVbMl08MD8tcjpyKSsy
Kk1hdGguUEktVGEpJSgyKk1hdGguUEkpfWZ1bmN0aW9uIHZyKG4sdCxlKXt2YXIgcj1Hby5yYW5n
ZShuLHQtVGEsZSkuY29uY2F0KHQpO3JldHVybiBmdW5jdGlvbihuKXtyZXR1cm4gci5tYXAoZnVu
Y3Rpb24odCl7cmV0dXJuW24sdF19KX19ZnVuY3Rpb24gZHIobix0LGUpe3ZhciByPUdvLnJhbmdl
KG4sdC1UYSxlKS5jb25jYXQodCk7cmV0dXJuIGZ1bmN0aW9uKG4pe3JldHVybiByLm1hcChmdW5j
dGlvbih0KXtyZXR1cm5bdCxuXX0pfX1mdW5jdGlvbiBtcihuKXtyZXR1cm4gbi5zb3VyY2V9ZnVu
Y3Rpb24geXIobil7cmV0dXJuIG4udGFyZ2V0fWZ1bmN0aW9uIHhyKG4sdCxlLHIpe3ZhciB1PU1h
dGguY29zKHQpLGk9TWF0aC5zaW4odCksbz1NYXRoLmNvcyhyKSxhPU1hdGguc2luKHIpLGM9dSpN
YXRoLmNvcyhuKSxzPXUqTWF0aC5zaW4obiksbD1vKk1hdGguY29zKGUpLGY9bypNYXRoLnNpbihl
KSxoPTIqTWF0aC5hc2luKE1hdGguc3FydCh0dChyLXQpK3Uqbyp0dChlLW4pKSksZz0xL01hdGgu
c2luKGgpLHA9aD9mdW5jdGlvbihuKXt2YXIgdD1NYXRoLnNpbihuKj1oKSpnLGU9TWF0aC5zaW4o
aC1uKSpnLHI9ZSpjK3QqbCx1PWUqcyt0KmYsbz1lKmkrdCphO3JldHVybltNYXRoLmF0YW4yKHUs
cikqUmEsTWF0aC5hdGFuMihvLE1hdGguc3FydChyKnIrdSp1KSkqUmFdfTpmdW5jdGlvbigpe3Jl
dHVybltuKlJhLHQqUmFdfTtyZXR1cm4gcC5kaXN0YW5jZT1oLHB9ZnVuY3Rpb24gTXIoKXtmdW5j
dGlvbiBuKG4sdSl7dmFyIGk9TWF0aC5zaW4odSo9emEpLG89TWF0aC5jb3ModSksYT1mYSgobio9
emEpLXQpLGM9TWF0aC5jb3MoYSk7T2MrPU1hdGguYXRhbjIoTWF0aC5zcXJ0KChhPW8qTWF0aC5z
aW4oYSkpKmErKGE9cippLWUqbypjKSphKSxlKmkrcipvKmMpLHQ9bixlPWkscj1vfXZhciB0LGUs
cjtJYy5wb2ludD1mdW5jdGlvbih1LGkpe3Q9dSp6YSxlPU1hdGguc2luKGkqPXphKSxyPU1hdGgu
Y29zKGkpLEljLnBvaW50PW59LEljLmxpbmVFbmQ9ZnVuY3Rpb24oKXtJYy5wb2ludD1JYy5saW5l
RW5kPXZ9fWZ1bmN0aW9uIF9yKG4sdCl7ZnVuY3Rpb24gZSh0LGUpe3ZhciByPU1hdGguY29zKHQp
LHU9TWF0aC5jb3MoZSksaT1uKHIqdSk7cmV0dXJuW2kqdSpNYXRoLnNpbih0KSxpKk1hdGguc2lu
KGUpXX1yZXR1cm4gZS5pbnZlcnQ9ZnVuY3Rpb24obixlKXt2YXIgcj1NYXRoLnNxcnQobipuK2Uq
ZSksdT10KHIpLGk9TWF0aC5zaW4odSksbz1NYXRoLmNvcyh1KTtyZXR1cm5bTWF0aC5hdGFuMihu
KmkscipvKSxNYXRoLmFzaW4ociYmZSppL3IpXX0sZX1mdW5jdGlvbiBicihuLHQpe2Z1bmN0aW9u
IGUobix0KXtvPjA/LUxhK1RhPnQmJih0PS1MYStUYSk6dD5MYS1UYSYmKHQ9TGEtVGEpO3ZhciBl
PW8vTWF0aC5wb3codSh0KSxpKTtyZXR1cm5bZSpNYXRoLnNpbihpKm4pLG8tZSpNYXRoLmNvcyhp
Km4pXX12YXIgcj1NYXRoLmNvcyhuKSx1PWZ1bmN0aW9uKG4pe3JldHVybiBNYXRoLnRhbihDYS80
K24vMil9LGk9bj09PXQ/TWF0aC5zaW4obik6TWF0aC5sb2coci9NYXRoLmNvcyh0KSkvTWF0aC5s
b2codSh0KS91KG4pKSxvPXIqTWF0aC5wb3codShuKSxpKS9pO3JldHVybiBpPyhlLmludmVydD1m
dW5jdGlvbihuLHQpe3ZhciBlPW8tdCxyPUIoaSkqTWF0aC5zcXJ0KG4qbitlKmUpO3JldHVybltN
YXRoLmF0YW4yKG4sZSkvaSwyKk1hdGguYXRhbihNYXRoLnBvdyhvL3IsMS9pKSktTGFdfSxlKTpT
cn1mdW5jdGlvbiB3cihuLHQpe2Z1bmN0aW9uIGUobix0KXt2YXIgZT1pLXQ7cmV0dXJuW2UqTWF0
aC5zaW4odSpuKSxpLWUqTWF0aC5jb3ModSpuKV19dmFyIHI9TWF0aC5jb3MobiksdT1uPT09dD9N
YXRoLnNpbihuKTooci1NYXRoLmNvcyh0KSkvKHQtbiksaT1yL3UrbjtyZXR1cm4gZmEodSk8VGE/
YXI6KGUuaW52ZXJ0PWZ1bmN0aW9uKG4sdCl7dmFyIGU9aS10O3JldHVybltNYXRoLmF0YW4yKG4s
ZSkvdSxpLUIodSkqTWF0aC5zcXJ0KG4qbitlKmUpXX0sZSl9ZnVuY3Rpb24gU3Iobix0KXtyZXR1
cm5bbixNYXRoLmxvZyhNYXRoLnRhbihDYS80K3QvMikpXX1mdW5jdGlvbiBrcihuKXt2YXIgdCxl
PXVyKG4pLHI9ZS5zY2FsZSx1PWUudHJhbnNsYXRlLGk9ZS5jbGlwRXh0ZW50O3JldHVybiBlLnNj
YWxlPWZ1bmN0aW9uKCl7dmFyIG49ci5hcHBseShlLGFyZ3VtZW50cyk7cmV0dXJuIG49PT1lP3Q/
ZS5jbGlwRXh0ZW50KG51bGwpOmU6bn0sZS50cmFuc2xhdGU9ZnVuY3Rpb24oKXt2YXIgbj11LmFw
cGx5KGUsYXJndW1lbnRzKTtyZXR1cm4gbj09PWU/dD9lLmNsaXBFeHRlbnQobnVsbCk6ZTpufSxl
LmNsaXBFeHRlbnQ9ZnVuY3Rpb24obil7dmFyIG89aS5hcHBseShlLGFyZ3VtZW50cyk7aWYobz09
PWUpe2lmKHQ9bnVsbD09bil7dmFyIGE9Q2EqcigpLGM9dSgpO2koW1tjWzBdLWEsY1sxXS1hXSxb
Y1swXSthLGNbMV0rYV1dKX19ZWxzZSB0JiYobz1udWxsKTtyZXR1cm4gb30sZS5jbGlwRXh0ZW50
KG51bGwpfWZ1bmN0aW9uIEVyKG4sdCl7cmV0dXJuW01hdGgubG9nKE1hdGgudGFuKENhLzQrdC8y
KSksLW5dfWZ1bmN0aW9uIEFyKG4pe3JldHVybiBuWzBdfWZ1bmN0aW9uIENyKG4pe3JldHVybiBu
WzFdfWZ1bmN0aW9uIE5yKG4pe2Zvcih2YXIgdD1uLmxlbmd0aCxlPVswLDFdLHI9Mix1PTI7dD51
O3UrKyl7Zm9yKDtyPjEmJkoobltlW3ItMl1dLG5bZVtyLTFdXSxuW3VdKTw9MDspLS1yO2Vbcisr
XT11fXJldHVybiBlLnNsaWNlKDAscil9ZnVuY3Rpb24gTHIobix0KXtyZXR1cm4gblswXS10WzBd
fHxuWzFdLXRbMV19ZnVuY3Rpb24gVHIobix0LGUpe3JldHVybihlWzBdLXRbMF0pKihuWzFdLXRb
MV0pPChlWzFdLXRbMV0pKihuWzBdLXRbMF0pfWZ1bmN0aW9uIHFyKG4sdCxlLHIpe3ZhciB1PW5b
MF0saT1lWzBdLG89dFswXS11LGE9clswXS1pLGM9blsxXSxzPWVbMV0sbD10WzFdLWMsZj1yWzFd
LXMsaD0oYSooYy1zKS1mKih1LWkpKS8oZipvLWEqbCk7cmV0dXJuW3UraCpvLGMraCpsXX1mdW5j
dGlvbiB6cihuKXt2YXIgdD1uWzBdLGU9bltuLmxlbmd0aC0xXTtyZXR1cm4hKHRbMF0tZVswXXx8
dFsxXS1lWzFdKX1mdW5jdGlvbiBScigpe3R1KHRoaXMpLHRoaXMuZWRnZT10aGlzLnNpdGU9dGhp
cy5jaXJjbGU9bnVsbH1mdW5jdGlvbiBEcihuKXt2YXIgdD1ucy5wb3AoKXx8bmV3IFJyO3JldHVy
biB0LnNpdGU9bix0fWZ1bmN0aW9uIFByKG4peyRyKG4pLEdjLnJlbW92ZShuKSxucy5wdXNoKG4p
LHR1KG4pfWZ1bmN0aW9uIFVyKG4pe3ZhciB0PW4uY2lyY2xlLGU9dC54LHI9dC5jeSx1PXt4OmUs
eTpyfSxpPW4uUCxvPW4uTixhPVtuXTtQcihuKTtmb3IodmFyIGM9aTtjLmNpcmNsZSYmZmEoZS1j
LmNpcmNsZS54KTxUYSYmZmEoci1jLmNpcmNsZS5jeSk8VGE7KWk9Yy5QLGEudW5zaGlmdChjKSxQ
cihjKSxjPWk7YS51bnNoaWZ0KGMpLCRyKGMpO2Zvcih2YXIgcz1vO3MuY2lyY2xlJiZmYShlLXMu
Y2lyY2xlLngpPFRhJiZmYShyLXMuY2lyY2xlLmN5KTxUYTspbz1zLk4sYS5wdXNoKHMpLFByKHMp
LHM9bzthLnB1c2gocyksJHIocyk7dmFyIGwsZj1hLmxlbmd0aDtmb3IobD0xO2Y+bDsrK2wpcz1h
W2xdLGM9YVtsLTFdLEtyKHMuZWRnZSxjLnNpdGUscy5zaXRlLHUpO2M9YVswXSxzPWFbZi0xXSxz
LmVkZ2U9V3IoYy5zaXRlLHMuc2l0ZSxudWxsLHUpLFZyKGMpLFZyKHMpfWZ1bmN0aW9uIGpyKG4p
e2Zvcih2YXIgdCxlLHIsdSxpPW4ueCxvPW4ueSxhPUdjLl87YTspaWYocj1IcihhLG8pLWkscj5U
YSlhPWEuTDtlbHNle2lmKHU9aS1GcihhLG8pLCEodT5UYSkpe3I+LVRhPyh0PWEuUCxlPWEpOnU+
LVRhPyh0PWEsZT1hLk4pOnQ9ZT1hO2JyZWFrfWlmKCFhLlIpe3Q9YTticmVha31hPWEuUn12YXIg
Yz1EcihuKTtpZihHYy5pbnNlcnQodCxjKSx0fHxlKXtpZih0PT09ZSlyZXR1cm4gJHIodCksZT1E
cih0LnNpdGUpLEdjLmluc2VydChjLGUpLGMuZWRnZT1lLmVkZ2U9V3IodC5zaXRlLGMuc2l0ZSks
VnIodCksVnIoZSksdm9pZCAwO2lmKCFlKXJldHVybiBjLmVkZ2U9V3IodC5zaXRlLGMuc2l0ZSks
dm9pZCAwOyRyKHQpLCRyKGUpO3ZhciBzPXQuc2l0ZSxsPXMueCxmPXMueSxoPW4ueC1sLGc9bi55
LWYscD1lLnNpdGUsdj1wLngtbCxkPXAueS1mLG09MiooaCpkLWcqdikseT1oKmgrZypnLHg9dip2
K2QqZCxNPXt4OihkKnktZyp4KS9tK2wseTooaCp4LXYqeSkvbStmfTtLcihlLmVkZ2UscyxwLE0p
LGMuZWRnZT1XcihzLG4sbnVsbCxNKSxlLmVkZ2U9V3IobixwLG51bGwsTSksVnIodCksVnIoZSl9
fWZ1bmN0aW9uIEhyKG4sdCl7dmFyIGU9bi5zaXRlLHI9ZS54LHU9ZS55LGk9dS10O2lmKCFpKXJl
dHVybiByO3ZhciBvPW4uUDtpZighbylyZXR1cm4tMS8wO2U9by5zaXRlO3ZhciBhPWUueCxjPWUu
eSxzPWMtdDtpZighcylyZXR1cm4gYTt2YXIgbD1hLXIsZj0xL2ktMS9zLGg9bC9zO3JldHVybiBm
PygtaCtNYXRoLnNxcnQoaCpoLTIqZioobCpsLygtMipzKS1jK3MvMit1LWkvMikpKS9mK3I6KHIr
YSkvMn1mdW5jdGlvbiBGcihuLHQpe3ZhciBlPW4uTjtpZihlKXJldHVybiBIcihlLHQpO3ZhciBy
PW4uc2l0ZTtyZXR1cm4gci55PT09dD9yLng6MS8wfWZ1bmN0aW9uIE9yKG4pe3RoaXMuc2l0ZT1u
LHRoaXMuZWRnZXM9W119ZnVuY3Rpb24gSXIobil7Zm9yKHZhciB0LGUscix1LGksbyxhLGMscyxs
LGY9blswXVswXSxoPW5bMV1bMF0sZz1uWzBdWzFdLHA9blsxXVsxXSx2PVdjLGQ9di5sZW5ndGg7
ZC0tOylpZihpPXZbZF0saSYmaS5wcmVwYXJlKCkpZm9yKGE9aS5lZGdlcyxjPWEubGVuZ3RoLG89
MDtjPm87KWw9YVtvXS5lbmQoKSxyPWwueCx1PWwueSxzPWFbKytvJWNdLnN0YXJ0KCksdD1zLngs
ZT1zLnksKGZhKHItdCk+VGF8fGZhKHUtZSk+VGEpJiYoYS5zcGxpY2UobywwLG5ldyBRcihHcihp
LnNpdGUsbCxmYShyLWYpPFRhJiZwLXU+VGE/e3g6Zix5OmZhKHQtZik8VGE/ZTpwfTpmYSh1LXAp
PFRhJiZoLXI+VGE/e3g6ZmEoZS1wKTxUYT90OmgseTpwfTpmYShyLWgpPFRhJiZ1LWc+VGE/e3g6
aCx5OmZhKHQtaCk8VGE/ZTpnfTpmYSh1LWcpPFRhJiZyLWY+VGE/e3g6ZmEoZS1nKTxUYT90OmYs
eTpnfTpudWxsKSxpLnNpdGUsbnVsbCkpLCsrYyl9ZnVuY3Rpb24gWXIobix0KXtyZXR1cm4gdC5h
bmdsZS1uLmFuZ2xlfWZ1bmN0aW9uIFpyKCl7dHUodGhpcyksdGhpcy54PXRoaXMueT10aGlzLmFy
Yz10aGlzLnNpdGU9dGhpcy5jeT1udWxsfWZ1bmN0aW9uIFZyKG4pe3ZhciB0PW4uUCxlPW4uTjtp
Zih0JiZlKXt2YXIgcj10LnNpdGUsdT1uLnNpdGUsaT1lLnNpdGU7aWYociE9PWkpe3ZhciBvPXUu
eCxhPXUueSxjPXIueC1vLHM9ci55LWEsbD1pLngtbyxmPWkueS1hLGg9MiooYypmLXMqbCk7aWYo
IShoPj0tcWEpKXt2YXIgZz1jKmMrcypzLHA9bCpsK2YqZix2PShmKmctcypwKS9oLGQ9KGMqcC1s
KmcpL2gsZj1kK2EsbT10cy5wb3AoKXx8bmV3IFpyO20uYXJjPW4sbS5zaXRlPXUsbS54PXYrbyxt
Lnk9ZitNYXRoLnNxcnQodip2K2QqZCksbS5jeT1mLG4uY2lyY2xlPW07Zm9yKHZhciB5PW51bGws
eD1RYy5fO3g7KWlmKG0ueTx4Lnl8fG0ueT09PXgueSYmbS54PD14Lngpe2lmKCF4Lkwpe3k9eC5Q
O2JyZWFrfXg9eC5MfWVsc2V7aWYoIXguUil7eT14O2JyZWFrfXg9eC5SfVFjLmluc2VydCh5LG0p
LHl8fChLYz1tKX19fX1mdW5jdGlvbiAkcihuKXt2YXIgdD1uLmNpcmNsZTt0JiYodC5QfHwoS2M9
dC5OKSxRYy5yZW1vdmUodCksdHMucHVzaCh0KSx0dSh0KSxuLmNpcmNsZT1udWxsKX1mdW5jdGlv
biBYcihuKXtmb3IodmFyIHQsZT1KYyxyPUZlKG5bMF1bMF0sblswXVsxXSxuWzFdWzBdLG5bMV1b
MV0pLHU9ZS5sZW5ndGg7dS0tOyl0PWVbdV0sKCFCcih0LG4pfHwhcih0KXx8ZmEodC5hLngtdC5i
LngpPFRhJiZmYSh0LmEueS10LmIueSk8VGEpJiYodC5hPXQuYj1udWxsLGUuc3BsaWNlKHUsMSkp
fWZ1bmN0aW9uIEJyKG4sdCl7dmFyIGU9bi5iO2lmKGUpcmV0dXJuITA7dmFyIHIsdSxpPW4uYSxv
PXRbMF1bMF0sYT10WzFdWzBdLGM9dFswXVsxXSxzPXRbMV1bMV0sbD1uLmwsZj1uLnIsaD1sLngs
Zz1sLnkscD1mLngsdj1mLnksZD0oaCtwKS8yLG09KGcrdikvMjtpZih2PT09Zyl7aWYobz5kfHxk
Pj1hKXJldHVybjtpZihoPnApe2lmKGkpe2lmKGkueT49cylyZXR1cm59ZWxzZSBpPXt4OmQseTpj
fTtlPXt4OmQseTpzfX1lbHNle2lmKGkpe2lmKGkueTxjKXJldHVybn1lbHNlIGk9e3g6ZCx5OnN9
O2U9e3g6ZCx5OmN9fX1lbHNlIGlmKHI9KGgtcCkvKHYtZyksdT1tLXIqZCwtMT5yfHxyPjEpaWYo
aD5wKXtpZihpKXtpZihpLnk+PXMpcmV0dXJufWVsc2UgaT17eDooYy11KS9yLHk6Y307ZT17eDoo
cy11KS9yLHk6c319ZWxzZXtpZihpKXtpZihpLnk8YylyZXR1cm59ZWxzZSBpPXt4OihzLXUpL3Is
eTpzfTtlPXt4OihjLXUpL3IseTpjfX1lbHNlIGlmKHY+Zyl7aWYoaSl7aWYoaS54Pj1hKXJldHVy
bn1lbHNlIGk9e3g6byx5OnIqbyt1fTtlPXt4OmEseTpyKmErdX19ZWxzZXtpZihpKXtpZihpLng8
bylyZXR1cm59ZWxzZSBpPXt4OmEseTpyKmErdX07ZT17eDpvLHk6cipvK3V9fXJldHVybiBuLmE9
aSxuLmI9ZSwhMH1mdW5jdGlvbiBKcihuLHQpe3RoaXMubD1uLHRoaXMucj10LHRoaXMuYT10aGlz
LmI9bnVsbH1mdW5jdGlvbiBXcihuLHQsZSxyKXt2YXIgdT1uZXcgSnIobix0KTtyZXR1cm4gSmMu
cHVzaCh1KSxlJiZLcih1LG4sdCxlKSxyJiZLcih1LHQsbixyKSxXY1tuLmldLmVkZ2VzLnB1c2go
bmV3IFFyKHUsbix0KSksV2NbdC5pXS5lZGdlcy5wdXNoKG5ldyBRcih1LHQsbikpLHV9ZnVuY3Rp
b24gR3Iobix0LGUpe3ZhciByPW5ldyBKcihuLG51bGwpO3JldHVybiByLmE9dCxyLmI9ZSxKYy5w
dXNoKHIpLHJ9ZnVuY3Rpb24gS3Iobix0LGUscil7bi5hfHxuLmI/bi5sPT09ZT9uLmI9cjpuLmE9
cjoobi5hPXIsbi5sPXQsbi5yPWUpfWZ1bmN0aW9uIFFyKG4sdCxlKXt2YXIgcj1uLmEsdT1uLmI7
dGhpcy5lZGdlPW4sdGhpcy5zaXRlPXQsdGhpcy5hbmdsZT1lP01hdGguYXRhbjIoZS55LXQueSxl
LngtdC54KTpuLmw9PT10P01hdGguYXRhbjIodS54LXIueCxyLnktdS55KTpNYXRoLmF0YW4yKHIu
eC11LngsdS55LXIueSl9ZnVuY3Rpb24gbnUoKXt0aGlzLl89bnVsbH1mdW5jdGlvbiB0dShuKXtu
LlU9bi5DPW4uTD1uLlI9bi5QPW4uTj1udWxsfWZ1bmN0aW9uIGV1KG4sdCl7dmFyIGU9dCxyPXQu
Uix1PWUuVTt1P3UuTD09PWU/dS5MPXI6dS5SPXI6bi5fPXIsci5VPXUsZS5VPXIsZS5SPXIuTCxl
LlImJihlLlIuVT1lKSxyLkw9ZX1mdW5jdGlvbiBydShuLHQpe3ZhciBlPXQscj10LkwsdT1lLlU7
dT91Lkw9PT1lP3UuTD1yOnUuUj1yOm4uXz1yLHIuVT11LGUuVT1yLGUuTD1yLlIsZS5MJiYoZS5M
LlU9ZSksci5SPWV9ZnVuY3Rpb24gdXUobil7Zm9yKDtuLkw7KW49bi5MO3JldHVybiBufWZ1bmN0
aW9uIGl1KG4sdCl7dmFyIGUscix1LGk9bi5zb3J0KG91KS5wb3AoKTtmb3IoSmM9W10sV2M9bmV3
IEFycmF5KG4ubGVuZ3RoKSxHYz1uZXcgbnUsUWM9bmV3IG51OzspaWYodT1LYyxpJiYoIXV8fGku
eTx1Lnl8fGkueT09PXUueSYmaS54PHUueCkpKGkueCE9PWV8fGkueSE9PXIpJiYoV2NbaS5pXT1u
ZXcgT3IoaSksanIoaSksZT1pLngscj1pLnkpLGk9bi5wb3AoKTtlbHNle2lmKCF1KWJyZWFrO1Vy
KHUuYXJjKX10JiYoWHIodCksSXIodCkpO3ZhciBvPXtjZWxsczpXYyxlZGdlczpKY307cmV0dXJu
IEdjPVFjPUpjPVdjPW51bGwsb31mdW5jdGlvbiBvdShuLHQpe3JldHVybiB0Lnktbi55fHx0Lngt
bi54fWZ1bmN0aW9uIGF1KG4sdCxlKXtyZXR1cm4obi54LWUueCkqKHQueS1uLnkpLShuLngtdC54
KSooZS55LW4ueSl9ZnVuY3Rpb24gY3Uobil7cmV0dXJuIG4ueH1mdW5jdGlvbiBzdShuKXtyZXR1
cm4gbi55fWZ1bmN0aW9uIGx1KCl7cmV0dXJue2xlYWY6ITAsbm9kZXM6W10scG9pbnQ6bnVsbCx4
Om51bGwseTpudWxsfX1mdW5jdGlvbiBmdShuLHQsZSxyLHUsaSl7aWYoIW4odCxlLHIsdSxpKSl7
dmFyIG89LjUqKGUrdSksYT0uNSoocitpKSxjPXQubm9kZXM7Y1swXSYmZnUobixjWzBdLGUscixv
LGEpLGNbMV0mJmZ1KG4sY1sxXSxvLHIsdSxhKSxjWzJdJiZmdShuLGNbMl0sZSxhLG8saSksY1sz
XSYmZnUobixjWzNdLG8sYSx1LGkpfX1mdW5jdGlvbiBodShuLHQpe249R28ucmdiKG4pLHQ9R28u
cmdiKHQpO3ZhciBlPW4ucixyPW4uZyx1PW4uYixpPXQuci1lLG89dC5nLXIsYT10LmItdTtyZXR1
cm4gZnVuY3Rpb24obil7cmV0dXJuIiMiK010KE1hdGgucm91bmQoZStpKm4pKStNdChNYXRoLnJv
dW5kKHIrbypuKSkrTXQoTWF0aC5yb3VuZCh1K2EqbikpfX1mdW5jdGlvbiBndShuLHQpe3ZhciBl
LHI9e30sdT17fTtmb3IoZSBpbiBuKWUgaW4gdD9yW2VdPWR1KG5bZV0sdFtlXSk6dVtlXT1uW2Vd
O2ZvcihlIGluIHQpZSBpbiBufHwodVtlXT10W2VdKTtyZXR1cm4gZnVuY3Rpb24obil7Zm9yKGUg
aW4gcil1W2VdPXJbZV0obik7cmV0dXJuIHV9fWZ1bmN0aW9uIHB1KG4sdCl7cmV0dXJuIHQtPW49
K24sZnVuY3Rpb24oZSl7cmV0dXJuIG4rdCplfX1mdW5jdGlvbiB2dShuLHQpe3ZhciBlLHIsdSxp
PXJzLmxhc3RJbmRleD11cy5sYXN0SW5kZXg9MCxvPS0xLGE9W10sYz1bXTtmb3Iobis9IiIsdCs9
IiI7KGU9cnMuZXhlYyhuKSkmJihyPXVzLmV4ZWModCkpOykodT1yLmluZGV4KT5pJiYodT10LnN1
YnN0cmluZyhpLHUpLGFbb10/YVtvXSs9dTphWysrb109dSksKGU9ZVswXSk9PT0ocj1yWzBdKT9h
W29dP2Fbb10rPXI6YVsrK29dPXI6KGFbKytvXT1udWxsLGMucHVzaCh7aTpvLHg6cHUoZSxyKX0p
KSxpPXVzLmxhc3RJbmRleDtyZXR1cm4gaTx0Lmxlbmd0aCYmKHU9dC5zdWJzdHJpbmcoaSksYVtv
XT9hW29dKz11OmFbKytvXT11KSxhLmxlbmd0aDwyP2NbMF0/KHQ9Y1swXS54LGZ1bmN0aW9uKG4p
e3JldHVybiB0KG4pKyIifSk6ZnVuY3Rpb24oKXtyZXR1cm4gdH06KHQ9Yy5sZW5ndGgsZnVuY3Rp
b24obil7Zm9yKHZhciBlLHI9MDt0PnI7KytyKWFbKGU9Y1tyXSkuaV09ZS54KG4pO3JldHVybiBh
LmpvaW4oIiIpfSl9ZnVuY3Rpb24gZHUobix0KXtmb3IodmFyIGUscj1Hby5pbnRlcnBvbGF0b3Jz
Lmxlbmd0aDstLXI+PTAmJiEoZT1Hby5pbnRlcnBvbGF0b3JzW3JdKG4sdCkpOyk7cmV0dXJuIGV9
ZnVuY3Rpb24gbXUobix0KXt2YXIgZSxyPVtdLHU9W10saT1uLmxlbmd0aCxvPXQubGVuZ3RoLGE9
TWF0aC5taW4obi5sZW5ndGgsdC5sZW5ndGgpO2ZvcihlPTA7YT5lOysrZSlyLnB1c2goZHUobltl
XSx0W2VdKSk7Zm9yKDtpPmU7KytlKXVbZV09bltlXTtmb3IoO28+ZTsrK2UpdVtlXT10W2VdO3Jl
dHVybiBmdW5jdGlvbihuKXtmb3IoZT0wO2E+ZTsrK2UpdVtlXT1yW2VdKG4pO3JldHVybiB1fX1m
dW5jdGlvbiB5dShuKXtyZXR1cm4gZnVuY3Rpb24odCl7cmV0dXJuIDA+PXQ/MDp0Pj0xPzE6bih0
KX19ZnVuY3Rpb24geHUobil7cmV0dXJuIGZ1bmN0aW9uKHQpe3JldHVybiAxLW4oMS10KX19ZnVu
Y3Rpb24gTXUobil7cmV0dXJuIGZ1bmN0aW9uKHQpe3JldHVybi41KiguNT50P24oMip0KToyLW4o
Mi0yKnQpKX19ZnVuY3Rpb24gX3Uobil7cmV0dXJuIG4qbn1mdW5jdGlvbiBidShuKXtyZXR1cm4g
bipuKm59ZnVuY3Rpb24gd3Uobil7aWYoMD49bilyZXR1cm4gMDtpZihuPj0xKXJldHVybiAxO3Zh
ciB0PW4qbixlPXQqbjtyZXR1cm4gNCooLjU+bj9lOjMqKG4tdCkrZS0uNzUpfWZ1bmN0aW9uIFN1
KG4pe3JldHVybiBmdW5jdGlvbih0KXtyZXR1cm4gTWF0aC5wb3codCxuKX19ZnVuY3Rpb24ga3Uo
bil7cmV0dXJuIDEtTWF0aC5jb3MobipMYSl9ZnVuY3Rpb24gRXUobil7cmV0dXJuIE1hdGgucG93
KDIsMTAqKG4tMSkpfWZ1bmN0aW9uIEF1KG4pe3JldHVybiAxLU1hdGguc3FydCgxLW4qbil9ZnVu
Y3Rpb24gQ3Uobix0KXt2YXIgZTtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aDwyJiYodD0uNDUpLGFy
Z3VtZW50cy5sZW5ndGg/ZT10L05hKk1hdGguYXNpbigxL24pOihuPTEsZT10LzQpLGZ1bmN0aW9u
KHIpe3JldHVybiAxK24qTWF0aC5wb3coMiwtMTAqcikqTWF0aC5zaW4oKHItZSkqTmEvdCl9fWZ1
bmN0aW9uIE51KG4pe3JldHVybiBufHwobj0xLjcwMTU4KSxmdW5jdGlvbih0KXtyZXR1cm4gdCp0
KigobisxKSp0LW4pfX1mdW5jdGlvbiBMdShuKXtyZXR1cm4gMS8yLjc1Pm4/Ny41NjI1Km4qbjoy
LzIuNzU+bj83LjU2MjUqKG4tPTEuNS8yLjc1KSpuKy43NToyLjUvMi43NT5uPzcuNTYyNSoobi09
Mi4yNS8yLjc1KSpuKy45Mzc1OjcuNTYyNSoobi09Mi42MjUvMi43NSkqbisuOTg0Mzc1fWZ1bmN0
aW9uIFR1KG4sdCl7bj1Hby5oY2wobiksdD1Hby5oY2wodCk7dmFyIGU9bi5oLHI9bi5jLHU9bi5s
LGk9dC5oLWUsbz10LmMtcixhPXQubC11O3JldHVybiBpc05hTihvKSYmKG89MCxyPWlzTmFOKHIp
P3QuYzpyKSxpc05hTihpKT8oaT0wLGU9aXNOYU4oZSk/dC5oOmUpOmk+MTgwP2ktPTM2MDotMTgw
PmkmJihpKz0zNjApLGZ1bmN0aW9uKG4pe3JldHVybiBjdChlK2kqbixyK28qbix1K2EqbikrIiJ9
fWZ1bmN0aW9uIHF1KG4sdCl7bj1Hby5oc2wobiksdD1Hby5oc2wodCk7dmFyIGU9bi5oLHI9bi5z
LHU9bi5sLGk9dC5oLWUsbz10LnMtcixhPXQubC11O3JldHVybiBpc05hTihvKSYmKG89MCxyPWlz
TmFOKHIpP3QuczpyKSxpc05hTihpKT8oaT0wLGU9aXNOYU4oZSk/dC5oOmUpOmk+MTgwP2ktPTM2
MDotMTgwPmkmJihpKz0zNjApLGZ1bmN0aW9uKG4pe3JldHVybiBpdChlK2kqbixyK28qbix1K2Eq
bikrIiJ9fWZ1bmN0aW9uIHp1KG4sdCl7bj1Hby5sYWIobiksdD1Hby5sYWIodCk7dmFyIGU9bi5s
LHI9bi5hLHU9bi5iLGk9dC5sLWUsbz10LmEtcixhPXQuYi11O3JldHVybiBmdW5jdGlvbihuKXty
ZXR1cm4gZnQoZStpKm4scitvKm4sdSthKm4pKyIifX1mdW5jdGlvbiBSdShuLHQpe3JldHVybiB0
LT1uLGZ1bmN0aW9uKGUpe3JldHVybiBNYXRoLnJvdW5kKG4rdCplKX19ZnVuY3Rpb24gRHUobil7
dmFyIHQ9W24uYSxuLmJdLGU9W24uYyxuLmRdLHI9VXUodCksdT1QdSh0LGUpLGk9VXUoanUoZSx0
LC11KSl8fDA7dFswXSplWzFdPGVbMF0qdFsxXSYmKHRbMF0qPS0xLHRbMV0qPS0xLHIqPS0xLHUq
PS0xKSx0aGlzLnJvdGF0ZT0ocj9NYXRoLmF0YW4yKHRbMV0sdFswXSk6TWF0aC5hdGFuMigtZVsw
XSxlWzFdKSkqUmEsdGhpcy50cmFuc2xhdGU9W24uZSxuLmZdLHRoaXMuc2NhbGU9W3IsaV0sdGhp
cy5za2V3PWk/TWF0aC5hdGFuMih1LGkpKlJhOjB9ZnVuY3Rpb24gUHUobix0KXtyZXR1cm4gblsw
XSp0WzBdK25bMV0qdFsxXX1mdW5jdGlvbiBVdShuKXt2YXIgdD1NYXRoLnNxcnQoUHUobixuKSk7
cmV0dXJuIHQmJihuWzBdLz10LG5bMV0vPXQpLHR9ZnVuY3Rpb24ganUobix0LGUpe3JldHVybiBu
WzBdKz1lKnRbMF0sblsxXSs9ZSp0WzFdLG59ZnVuY3Rpb24gSHUobix0KXt2YXIgZSxyPVtdLHU9
W10saT1Hby50cmFuc2Zvcm0obiksbz1Hby50cmFuc2Zvcm0odCksYT1pLnRyYW5zbGF0ZSxjPW8u
dHJhbnNsYXRlLHM9aS5yb3RhdGUsbD1vLnJvdGF0ZSxmPWkuc2tldyxoPW8uc2tldyxnPWkuc2Nh
bGUscD1vLnNjYWxlO3JldHVybiBhWzBdIT1jWzBdfHxhWzFdIT1jWzFdPyhyLnB1c2goInRyYW5z
bGF0ZSgiLG51bGwsIiwiLG51bGwsIikiKSx1LnB1c2goe2k6MSx4OnB1KGFbMF0sY1swXSl9LHtp
OjMseDpwdShhWzFdLGNbMV0pfSkpOmNbMF18fGNbMV0/ci5wdXNoKCJ0cmFuc2xhdGUoIitjKyIp
Iik6ci5wdXNoKCIiKSxzIT1sPyhzLWw+MTgwP2wrPTM2MDpsLXM+MTgwJiYocys9MzYwKSx1LnB1
c2goe2k6ci5wdXNoKHIucG9wKCkrInJvdGF0ZSgiLG51bGwsIikiKS0yLHg6cHUocyxsKX0pKTps
JiZyLnB1c2goci5wb3AoKSsicm90YXRlKCIrbCsiKSIpLGYhPWg/dS5wdXNoKHtpOnIucHVzaChy
LnBvcCgpKyJza2V3WCgiLG51bGwsIikiKS0yLHg6cHUoZixoKX0pOmgmJnIucHVzaChyLnBvcCgp
KyJza2V3WCgiK2grIikiKSxnWzBdIT1wWzBdfHxnWzFdIT1wWzFdPyhlPXIucHVzaChyLnBvcCgp
KyJzY2FsZSgiLG51bGwsIiwiLG51bGwsIikiKSx1LnB1c2goe2k6ZS00LHg6cHUoZ1swXSxwWzBd
KX0se2k6ZS0yLHg6cHUoZ1sxXSxwWzFdKX0pKTooMSE9cFswXXx8MSE9cFsxXSkmJnIucHVzaChy
LnBvcCgpKyJzY2FsZSgiK3ArIikiKSxlPXUubGVuZ3RoLGZ1bmN0aW9uKG4pe2Zvcih2YXIgdCxp
PS0xOysraTxlOylyWyh0PXVbaV0pLmldPXQueChuKTtyZXR1cm4gci5qb2luKCIiKX19ZnVuY3Rp
b24gRnUobix0KXtyZXR1cm4gdD10LShuPStuKT8xLyh0LW4pOjAsZnVuY3Rpb24oZSl7cmV0dXJu
KGUtbikqdH19ZnVuY3Rpb24gT3Uobix0KXtyZXR1cm4gdD10LShuPStuKT8xLyh0LW4pOjAsZnVu
Y3Rpb24oZSl7cmV0dXJuIE1hdGgubWF4KDAsTWF0aC5taW4oMSwoZS1uKSp0KSl9fWZ1bmN0aW9u
IEl1KG4pe2Zvcih2YXIgdD1uLnNvdXJjZSxlPW4udGFyZ2V0LHI9WnUodCxlKSx1PVt0XTt0IT09
cjspdD10LnBhcmVudCx1LnB1c2godCk7Zm9yKHZhciBpPXUubGVuZ3RoO2UhPT1yOyl1LnNwbGlj
ZShpLDAsZSksZT1lLnBhcmVudDtyZXR1cm4gdX1mdW5jdGlvbiBZdShuKXtmb3IodmFyIHQ9W10s
ZT1uLnBhcmVudDtudWxsIT1lOyl0LnB1c2gobiksbj1lLGU9ZS5wYXJlbnQ7cmV0dXJuIHQucHVz
aChuKSx0fWZ1bmN0aW9uIFp1KG4sdCl7aWYobj09PXQpcmV0dXJuIG47Zm9yKHZhciBlPVl1KG4p
LHI9WXUodCksdT1lLnBvcCgpLGk9ci5wb3AoKSxvPW51bGw7dT09PWk7KW89dSx1PWUucG9wKCks
aT1yLnBvcCgpO3JldHVybiBvfWZ1bmN0aW9uIFZ1KG4pe24uZml4ZWR8PTJ9ZnVuY3Rpb24gJHUo
bil7bi5maXhlZCY9LTd9ZnVuY3Rpb24gWHUobil7bi5maXhlZHw9NCxuLnB4PW4ueCxuLnB5PW4u
eX1mdW5jdGlvbiBCdShuKXtuLmZpeGVkJj0tNX1mdW5jdGlvbiBKdShuLHQsZSl7dmFyIHI9MCx1
PTA7aWYobi5jaGFyZ2U9MCwhbi5sZWFmKWZvcih2YXIgaSxvPW4ubm9kZXMsYT1vLmxlbmd0aCxj
PS0xOysrYzxhOylpPW9bY10sbnVsbCE9aSYmKEp1KGksdCxlKSxuLmNoYXJnZSs9aS5jaGFyZ2Us
cis9aS5jaGFyZ2UqaS5jeCx1Kz1pLmNoYXJnZSppLmN5KTtpZihuLnBvaW50KXtuLmxlYWZ8fChu
LnBvaW50LngrPU1hdGgucmFuZG9tKCktLjUsbi5wb2ludC55Kz1NYXRoLnJhbmRvbSgpLS41KTt2
YXIgcz10KmVbbi5wb2ludC5pbmRleF07bi5jaGFyZ2UrPW4ucG9pbnRDaGFyZ2U9cyxyKz1zKm4u
cG9pbnQueCx1Kz1zKm4ucG9pbnQueX1uLmN4PXIvbi5jaGFyZ2Usbi5jeT11L24uY2hhcmdlfWZ1
bmN0aW9uIFd1KG4sdCl7cmV0dXJuIEdvLnJlYmluZChuLHQsInNvcnQiLCJjaGlsZHJlbiIsInZh
bHVlIiksbi5ub2Rlcz1uLG4ubGlua3M9bmksbn1mdW5jdGlvbiBHdShuKXtyZXR1cm4gbi5jaGls
ZHJlbn1mdW5jdGlvbiBLdShuKXtyZXR1cm4gbi52YWx1ZX1mdW5jdGlvbiBRdShuLHQpe3JldHVy
biB0LnZhbHVlLW4udmFsdWV9ZnVuY3Rpb24gbmkobil7cmV0dXJuIEdvLm1lcmdlKG4ubWFwKGZ1
bmN0aW9uKG4pe3JldHVybihuLmNoaWxkcmVufHxbXSkubWFwKGZ1bmN0aW9uKHQpe3JldHVybntz
b3VyY2U6bix0YXJnZXQ6dH19KX0pKX1mdW5jdGlvbiB0aShuKXtyZXR1cm4gbi54fWZ1bmN0aW9u
IGVpKG4pe3JldHVybiBuLnl9ZnVuY3Rpb24gcmkobix0LGUpe24ueTA9dCxuLnk9ZX1mdW5jdGlv
biB1aShuKXtyZXR1cm4gR28ucmFuZ2Uobi5sZW5ndGgpfWZ1bmN0aW9uIGlpKG4pe2Zvcih2YXIg
dD0tMSxlPW5bMF0ubGVuZ3RoLHI9W107Kyt0PGU7KXJbdF09MDtyZXR1cm4gcn1mdW5jdGlvbiBv
aShuKXtmb3IodmFyIHQsZT0xLHI9MCx1PW5bMF1bMV0saT1uLmxlbmd0aDtpPmU7KytlKSh0PW5b
ZV1bMV0pPnUmJihyPWUsdT10KTtyZXR1cm4gcn1mdW5jdGlvbiBhaShuKXtyZXR1cm4gbi5yZWR1
Y2UoY2ksMCl9ZnVuY3Rpb24gY2kobix0KXtyZXR1cm4gbit0WzFdfWZ1bmN0aW9uIHNpKG4sdCl7
cmV0dXJuIGxpKG4sTWF0aC5jZWlsKE1hdGgubG9nKHQubGVuZ3RoKS9NYXRoLkxOMisxKSl9ZnVu
Y3Rpb24gbGkobix0KXtmb3IodmFyIGU9LTEscj0rblswXSx1PShuWzFdLXIpL3QsaT1bXTsrK2U8
PXQ7KWlbZV09dSplK3I7cmV0dXJuIGl9ZnVuY3Rpb24gZmkobil7cmV0dXJuW0dvLm1pbihuKSxH
by5tYXgobildfWZ1bmN0aW9uIGhpKG4sdCl7cmV0dXJuIG4ucGFyZW50PT10LnBhcmVudD8xOjJ9
ZnVuY3Rpb24gZ2kobil7dmFyIHQ9bi5jaGlsZHJlbjtyZXR1cm4gdCYmdC5sZW5ndGg/dFswXTpu
Ll90cmVlLnRocmVhZH1mdW5jdGlvbiBwaShuKXt2YXIgdCxlPW4uY2hpbGRyZW47cmV0dXJuIGUm
Jih0PWUubGVuZ3RoKT9lW3QtMV06bi5fdHJlZS50aHJlYWR9ZnVuY3Rpb24gdmkobix0KXt2YXIg
ZT1uLmNoaWxkcmVuO2lmKGUmJih1PWUubGVuZ3RoKSlmb3IodmFyIHIsdSxpPS0xOysraTx1Oyl0
KHI9dmkoZVtpXSx0KSxuKT4wJiYobj1yKTtyZXR1cm4gbn1mdW5jdGlvbiBkaShuLHQpe3JldHVy
biBuLngtdC54fWZ1bmN0aW9uIG1pKG4sdCl7cmV0dXJuIHQueC1uLnh9ZnVuY3Rpb24geWkobix0
KXtyZXR1cm4gbi5kZXB0aC10LmRlcHRofWZ1bmN0aW9uIHhpKG4sdCl7ZnVuY3Rpb24gZShuLHIp
e3ZhciB1PW4uY2hpbGRyZW47aWYodSYmKG89dS5sZW5ndGgpKWZvcih2YXIgaSxvLGE9bnVsbCxj
PS0xOysrYzxvOylpPXVbY10sZShpLGEpLGE9aTt0KG4scil9ZShuLG51bGwpfWZ1bmN0aW9uIE1p
KG4pe2Zvcih2YXIgdCxlPTAscj0wLHU9bi5jaGlsZHJlbixpPXUubGVuZ3RoOy0taT49MDspdD11
W2ldLl90cmVlLHQucHJlbGltKz1lLHQubW9kKz1lLGUrPXQuc2hpZnQrKHIrPXQuY2hhbmdlKX1m
dW5jdGlvbiBfaShuLHQsZSl7bj1uLl90cmVlLHQ9dC5fdHJlZTt2YXIgcj1lLyh0Lm51bWJlci1u
Lm51bWJlcik7bi5jaGFuZ2UrPXIsdC5jaGFuZ2UtPXIsdC5zaGlmdCs9ZSx0LnByZWxpbSs9ZSx0
Lm1vZCs9ZX1mdW5jdGlvbiBiaShuLHQsZSl7cmV0dXJuIG4uX3RyZWUuYW5jZXN0b3IucGFyZW50
PT10LnBhcmVudD9uLl90cmVlLmFuY2VzdG9yOmV9ZnVuY3Rpb24gd2kobix0KXtyZXR1cm4gbi52
YWx1ZS10LnZhbHVlfWZ1bmN0aW9uIFNpKG4sdCl7dmFyIGU9bi5fcGFja19uZXh0O24uX3BhY2tf
bmV4dD10LHQuX3BhY2tfcHJldj1uLHQuX3BhY2tfbmV4dD1lLGUuX3BhY2tfcHJldj10fWZ1bmN0
aW9uIGtpKG4sdCl7bi5fcGFja19uZXh0PXQsdC5fcGFja19wcmV2PW59ZnVuY3Rpb24gRWkobix0
KXt2YXIgZT10Lngtbi54LHI9dC55LW4ueSx1PW4ucit0LnI7cmV0dXJuLjk5OSp1KnU+ZSplK3Iq
cn1mdW5jdGlvbiBBaShuKXtmdW5jdGlvbiB0KG4pe2w9TWF0aC5taW4obi54LW4ucixsKSxmPU1h
dGgubWF4KG4ueCtuLnIsZiksaD1NYXRoLm1pbihuLnktbi5yLGgpLGc9TWF0aC5tYXgobi55K24u
cixnKX1pZigoZT1uLmNoaWxkcmVuKSYmKHM9ZS5sZW5ndGgpKXt2YXIgZSxyLHUsaSxvLGEsYyxz
LGw9MS8wLGY9LTEvMCxoPTEvMCxnPS0xLzA7aWYoZS5mb3JFYWNoKENpKSxyPWVbMF0sci54PS1y
LnIsci55PTAsdChyKSxzPjEmJih1PWVbMV0sdS54PXUucix1Lnk9MCx0KHUpLHM+MikpZm9yKGk9
ZVsyXSxUaShyLHUsaSksdChpKSxTaShyLGkpLHIuX3BhY2tfcHJldj1pLFNpKGksdSksdT1yLl9w
YWNrX25leHQsbz0zO3M+bztvKyspe1RpKHIsdSxpPWVbb10pO3ZhciBwPTAsdj0xLGQ9MTtmb3Io
YT11Ll9wYWNrX25leHQ7YSE9PXU7YT1hLl9wYWNrX25leHQsdisrKWlmKEVpKGEsaSkpe3A9MTti
cmVha31pZigxPT1wKWZvcihjPXIuX3BhY2tfcHJldjtjIT09YS5fcGFja19wcmV2JiYhRWkoYyxp
KTtjPWMuX3BhY2tfcHJldixkKyspO3A/KGQ+dnx8dj09ZCYmdS5yPHIucj9raShyLHU9YSk6a2ko
cj1jLHUpLG8tLSk6KFNpKHIsaSksdT1pLHQoaSkpfXZhciBtPShsK2YpLzIseT0oaCtnKS8yLHg9
MDtmb3Iobz0wO3M+bztvKyspaT1lW29dLGkueC09bSxpLnktPXkseD1NYXRoLm1heCh4LGkucitN
YXRoLnNxcnQoaS54KmkueCtpLnkqaS55KSk7bi5yPXgsZS5mb3JFYWNoKE5pKX19ZnVuY3Rpb24g
Q2kobil7bi5fcGFja19uZXh0PW4uX3BhY2tfcHJldj1ufWZ1bmN0aW9uIE5pKG4pe2RlbGV0ZSBu
Ll9wYWNrX25leHQsZGVsZXRlIG4uX3BhY2tfcHJldn1mdW5jdGlvbiBMaShuLHQsZSxyKXt2YXIg
dT1uLmNoaWxkcmVuO2lmKG4ueD10Kz1yKm4ueCxuLnk9ZSs9cipuLnksbi5yKj1yLHUpZm9yKHZh
ciBpPS0xLG89dS5sZW5ndGg7KytpPG87KUxpKHVbaV0sdCxlLHIpfWZ1bmN0aW9uIFRpKG4sdCxl
KXt2YXIgcj1uLnIrZS5yLHU9dC54LW4ueCxpPXQueS1uLnk7aWYociYmKHV8fGkpKXt2YXIgbz10
LnIrZS5yLGE9dSp1K2kqaTtvKj1vLHIqPXI7dmFyIGM9LjUrKHItbykvKDIqYSkscz1NYXRoLnNx
cnQoTWF0aC5tYXgoMCwyKm8qKHIrYSktKHItPWEpKnItbypvKSkvKDIqYSk7ZS54PW4ueCtjKnUr
cyppLGUueT1uLnkrYyppLXMqdX1lbHNlIGUueD1uLngrcixlLnk9bi55fWZ1bmN0aW9uIHFpKG4p
e3JldHVybiAxK0dvLm1heChuLGZ1bmN0aW9uKG4pe3JldHVybiBuLnl9KX1mdW5jdGlvbiB6aShu
KXtyZXR1cm4gbi5yZWR1Y2UoZnVuY3Rpb24obix0KXtyZXR1cm4gbit0Lnh9LDApL24ubGVuZ3Ro
fWZ1bmN0aW9uIFJpKG4pe3ZhciB0PW4uY2hpbGRyZW47cmV0dXJuIHQmJnQubGVuZ3RoP1JpKHRb
MF0pOm59ZnVuY3Rpb24gRGkobil7dmFyIHQsZT1uLmNoaWxkcmVuO3JldHVybiBlJiYodD1lLmxl
bmd0aCk/RGkoZVt0LTFdKTpufWZ1bmN0aW9uIFBpKG4pe3JldHVybnt4Om4ueCx5Om4ueSxkeDpu
LmR4LGR5Om4uZHl9fWZ1bmN0aW9uIFVpKG4sdCl7dmFyIGU9bi54K3RbM10scj1uLnkrdFswXSx1
PW4uZHgtdFsxXS10WzNdLGk9bi5keS10WzBdLXRbMl07cmV0dXJuIDA+dSYmKGUrPXUvMix1PTAp
LDA+aSYmKHIrPWkvMixpPTApLHt4OmUseTpyLGR4OnUsZHk6aX19ZnVuY3Rpb24gamkobil7dmFy
IHQ9blswXSxlPW5bbi5sZW5ndGgtMV07cmV0dXJuIGU+dD9bdCxlXTpbZSx0XX1mdW5jdGlvbiBI
aShuKXtyZXR1cm4gbi5yYW5nZUV4dGVudD9uLnJhbmdlRXh0ZW50KCk6amkobi5yYW5nZSgpKX1m
dW5jdGlvbiBGaShuLHQsZSxyKXt2YXIgdT1lKG5bMF0sblsxXSksaT1yKHRbMF0sdFsxXSk7cmV0
dXJuIGZ1bmN0aW9uKG4pe3JldHVybiBpKHUobikpfX1mdW5jdGlvbiBPaShuLHQpe3ZhciBlLHI9
MCx1PW4ubGVuZ3RoLTEsaT1uW3JdLG89blt1XTtyZXR1cm4gaT5vJiYoZT1yLHI9dSx1PWUsZT1p
LGk9byxvPWUpLG5bcl09dC5mbG9vcihpKSxuW3VdPXQuY2VpbChvKSxufWZ1bmN0aW9uIElpKG4p
e3JldHVybiBuP3tmbG9vcjpmdW5jdGlvbih0KXtyZXR1cm4gTWF0aC5mbG9vcih0L24pKm59LGNl
aWw6ZnVuY3Rpb24odCl7cmV0dXJuIE1hdGguY2VpbCh0L24pKm59fTp2c31mdW5jdGlvbiBZaShu
LHQsZSxyKXt2YXIgdT1bXSxpPVtdLG89MCxhPU1hdGgubWluKG4ubGVuZ3RoLHQubGVuZ3RoKS0x
O2ZvcihuW2FdPG5bMF0mJihuPW4uc2xpY2UoKS5yZXZlcnNlKCksdD10LnNsaWNlKCkucmV2ZXJz
ZSgpKTsrK288PWE7KXUucHVzaChlKG5bby0xXSxuW29dKSksaS5wdXNoKHIodFtvLTFdLHRbb10p
KTtyZXR1cm4gZnVuY3Rpb24odCl7dmFyIGU9R28uYmlzZWN0KG4sdCwxLGEpLTE7cmV0dXJuIGlb
ZV0odVtlXSh0KSl9fWZ1bmN0aW9uIFppKG4sdCxlLHIpe2Z1bmN0aW9uIHUoKXt2YXIgdT1NYXRo
Lm1pbihuLmxlbmd0aCx0Lmxlbmd0aCk+Mj9ZaTpGaSxjPXI/T3U6RnU7cmV0dXJuIG89dShuLHQs
YyxlKSxhPXUodCxuLGMsZHUpLGl9ZnVuY3Rpb24gaShuKXtyZXR1cm4gbyhuKX12YXIgbyxhO3Jl
dHVybiBpLmludmVydD1mdW5jdGlvbihuKXtyZXR1cm4gYShuKX0saS5kb21haW49ZnVuY3Rpb24o
dCl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KG49dC5tYXAoTnVtYmVyKSx1KCkpOm59LGkucmFu
Z2U9ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KHQ9bix1KCkpOnR9LGkucmFu
Z2VSb3VuZD1mdW5jdGlvbihuKXtyZXR1cm4gaS5yYW5nZShuKS5pbnRlcnBvbGF0ZShSdSl9LGku
Y2xhbXA9ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KHI9bix1KCkpOnJ9LGku
aW50ZXJwb2xhdGU9ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KGU9bix1KCkp
OmV9LGkudGlja3M9ZnVuY3Rpb24odCl7cmV0dXJuIEJpKG4sdCl9LGkudGlja0Zvcm1hdD1mdW5j
dGlvbih0LGUpe3JldHVybiBKaShuLHQsZSl9LGkubmljZT1mdW5jdGlvbih0KXtyZXR1cm4gJGko
bix0KSx1KCl9LGkuY29weT1mdW5jdGlvbigpe3JldHVybiBaaShuLHQsZSxyKX0sdSgpfWZ1bmN0
aW9uIFZpKG4sdCl7cmV0dXJuIEdvLnJlYmluZChuLHQsInJhbmdlIiwicmFuZ2VSb3VuZCIsImlu
dGVycG9sYXRlIiwiY2xhbXAiKX1mdW5jdGlvbiAkaShuLHQpe3JldHVybiBPaShuLElpKFhpKG4s
dClbMl0pKX1mdW5jdGlvbiBYaShuLHQpe251bGw9PXQmJih0PTEwKTt2YXIgZT1qaShuKSxyPWVb
MV0tZVswXSx1PU1hdGgucG93KDEwLE1hdGguZmxvb3IoTWF0aC5sb2coci90KS9NYXRoLkxOMTAp
KSxpPXQvcip1O3JldHVybi4xNT49aT91Kj0xMDouMzU+PWk/dSo9NTouNzU+PWkmJih1Kj0yKSxl
WzBdPU1hdGguY2VpbChlWzBdL3UpKnUsZVsxXT1NYXRoLmZsb29yKGVbMV0vdSkqdSsuNSp1LGVb
Ml09dSxlfWZ1bmN0aW9uIEJpKG4sdCl7cmV0dXJuIEdvLnJhbmdlLmFwcGx5KEdvLFhpKG4sdCkp
fWZ1bmN0aW9uIEppKG4sdCxlKXt2YXIgcj1YaShuLHQpO2lmKGUpe3ZhciB1PXJjLmV4ZWMoZSk7
aWYodS5zaGlmdCgpLCJzIj09PXVbOF0pe3ZhciBpPUdvLmZvcm1hdFByZWZpeChNYXRoLm1heChm
YShyWzBdKSxmYShyWzFdKSkpO3JldHVybiB1WzddfHwodVs3XT0iLiIrV2koaS5zY2FsZShyWzJd
KSkpLHVbOF09ImYiLGU9R28uZm9ybWF0KHUuam9pbigiIikpLGZ1bmN0aW9uKG4pe3JldHVybiBl
KGkuc2NhbGUobikpK2kuc3ltYm9sfX11WzddfHwodVs3XT0iLiIrR2kodVs4XSxyKSksZT11Lmpv
aW4oIiIpfWVsc2UgZT0iLC4iK1dpKHJbMl0pKyJmIjtyZXR1cm4gR28uZm9ybWF0KGUpfWZ1bmN0
aW9uIFdpKG4pe3JldHVybi1NYXRoLmZsb29yKE1hdGgubG9nKG4pL01hdGguTE4xMCsuMDEpfWZ1
bmN0aW9uIEdpKG4sdCl7dmFyIGU9V2kodFsyXSk7cmV0dXJuIG4gaW4gZHM/TWF0aC5hYnMoZS1X
aShNYXRoLm1heChmYSh0WzBdKSxmYSh0WzFdKSkpKSsgKygiZSIhPT1uKTplLTIqKCIlIj09PW4p
fWZ1bmN0aW9uIEtpKG4sdCxlLHIpe2Z1bmN0aW9uIHUobil7cmV0dXJuKGU/TWF0aC5sb2coMD5u
PzA6bik6LU1hdGgubG9nKG4+MD8wOi1uKSkvTWF0aC5sb2codCl9ZnVuY3Rpb24gaShuKXtyZXR1
cm4gZT9NYXRoLnBvdyh0LG4pOi1NYXRoLnBvdyh0LC1uKX1mdW5jdGlvbiBvKHQpe3JldHVybiBu
KHUodCkpfXJldHVybiBvLmludmVydD1mdW5jdGlvbih0KXtyZXR1cm4gaShuLmludmVydCh0KSl9
LG8uZG9tYWluPWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhlPXRbMF0+PTAs
bi5kb21haW4oKHI9dC5tYXAoTnVtYmVyKSkubWFwKHUpKSxvKTpyfSxvLmJhc2U9ZnVuY3Rpb24o
ZSl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KHQ9K2Usbi5kb21haW4oci5tYXAodSkpLG8pOnR9
LG8ubmljZT1mdW5jdGlvbigpe3ZhciB0PU9pKHIubWFwKHUpLGU/TWF0aDp5cyk7cmV0dXJuIG4u
ZG9tYWluKHQpLHI9dC5tYXAoaSksb30sby50aWNrcz1mdW5jdGlvbigpe3ZhciBuPWppKHIpLG89
W10sYT1uWzBdLGM9blsxXSxzPU1hdGguZmxvb3IodShhKSksbD1NYXRoLmNlaWwodShjKSksZj10
JTE/Mjp0O2lmKGlzRmluaXRlKGwtcykpe2lmKGUpe2Zvcig7bD5zO3MrKylmb3IodmFyIGg9MTtm
Pmg7aCsrKW8ucHVzaChpKHMpKmgpO28ucHVzaChpKHMpKX1lbHNlIGZvcihvLnB1c2goaShzKSk7
cysrPGw7KWZvcih2YXIgaD1mLTE7aD4wO2gtLSlvLnB1c2goaShzKSpoKTtmb3Iocz0wO29bc108
YTtzKyspO2ZvcihsPW8ubGVuZ3RoO29bbC0xXT5jO2wtLSk7bz1vLnNsaWNlKHMsbCl9cmV0dXJu
IG99LG8udGlja0Zvcm1hdD1mdW5jdGlvbihuLHQpe2lmKCFhcmd1bWVudHMubGVuZ3RoKXJldHVy
biBtczthcmd1bWVudHMubGVuZ3RoPDI/dD1tczoiZnVuY3Rpb24iIT10eXBlb2YgdCYmKHQ9R28u
Zm9ybWF0KHQpKTt2YXIgcixhPU1hdGgubWF4KC4xLG4vby50aWNrcygpLmxlbmd0aCksYz1lPyhy
PTFlLTEyLE1hdGguY2VpbCk6KHI9LTFlLTEyLE1hdGguZmxvb3IpO3JldHVybiBmdW5jdGlvbihu
KXtyZXR1cm4gbi9pKGModShuKStyKSk8PWE/dChuKToiIn19LG8uY29weT1mdW5jdGlvbigpe3Jl
dHVybiBLaShuLmNvcHkoKSx0LGUscil9LFZpKG8sbil9ZnVuY3Rpb24gUWkobix0LGUpe2Z1bmN0
aW9uIHIodCl7cmV0dXJuIG4odSh0KSl9dmFyIHU9bm8odCksaT1ubygxL3QpO3JldHVybiByLmlu
dmVydD1mdW5jdGlvbih0KXtyZXR1cm4gaShuLmludmVydCh0KSl9LHIuZG9tYWluPWZ1bmN0aW9u
KHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhuLmRvbWFpbigoZT10Lm1hcChOdW1iZXIpKS5t
YXAodSkpLHIpOmV9LHIudGlja3M9ZnVuY3Rpb24obil7cmV0dXJuIEJpKGUsbil9LHIudGlja0Zv
cm1hdD1mdW5jdGlvbihuLHQpe3JldHVybiBKaShlLG4sdCl9LHIubmljZT1mdW5jdGlvbihuKXty
ZXR1cm4gci5kb21haW4oJGkoZSxuKSl9LHIuZXhwb25lbnQ9ZnVuY3Rpb24obyl7cmV0dXJuIGFy
Z3VtZW50cy5sZW5ndGg/KHU9bm8odD1vKSxpPW5vKDEvdCksbi5kb21haW4oZS5tYXAodSkpLHIp
OnR9LHIuY29weT1mdW5jdGlvbigpe3JldHVybiBRaShuLmNvcHkoKSx0LGUpfSxWaShyLG4pfWZ1
bmN0aW9uIG5vKG4pe3JldHVybiBmdW5jdGlvbih0KXtyZXR1cm4gMD50Py1NYXRoLnBvdygtdCxu
KTpNYXRoLnBvdyh0LG4pfX1mdW5jdGlvbiB0byhuLHQpe2Z1bmN0aW9uIGUoZSl7cmV0dXJuIGlb
KCh1LmdldChlKXx8KCJyYW5nZSI9PT10LnQ/dS5zZXQoZSxuLnB1c2goZSkpOjAvMCkpLTEpJWku
bGVuZ3RoXX1mdW5jdGlvbiByKHQsZSl7cmV0dXJuIEdvLnJhbmdlKG4ubGVuZ3RoKS5tYXAoZnVu
Y3Rpb24obil7cmV0dXJuIHQrZSpufSl9dmFyIHUsaSxhO3JldHVybiBlLmRvbWFpbj1mdW5jdGlv
bihyKXtpZighYXJndW1lbnRzLmxlbmd0aClyZXR1cm4gbjtuPVtdLHU9bmV3IG87Zm9yKHZhciBp
LGE9LTEsYz1yLmxlbmd0aDsrK2E8YzspdS5oYXMoaT1yW2FdKXx8dS5zZXQoaSxuLnB1c2goaSkp
O3JldHVybiBlW3QudF0uYXBwbHkoZSx0LmEpfSxlLnJhbmdlPWZ1bmN0aW9uKG4pe3JldHVybiBh
cmd1bWVudHMubGVuZ3RoPyhpPW4sYT0wLHQ9e3Q6InJhbmdlIixhOmFyZ3VtZW50c30sZSk6aX0s
ZS5yYW5nZVBvaW50cz1mdW5jdGlvbih1LG8pe2FyZ3VtZW50cy5sZW5ndGg8MiYmKG89MCk7dmFy
IGM9dVswXSxzPXVbMV0sbD0ocy1jKS8oTWF0aC5tYXgoMSxuLmxlbmd0aC0xKStvKTtyZXR1cm4g
aT1yKG4ubGVuZ3RoPDI/KGMrcykvMjpjK2wqby8yLGwpLGE9MCx0PXt0OiJyYW5nZVBvaW50cyIs
YTphcmd1bWVudHN9LGV9LGUucmFuZ2VCYW5kcz1mdW5jdGlvbih1LG8sYyl7YXJndW1lbnRzLmxl
bmd0aDwyJiYobz0wKSxhcmd1bWVudHMubGVuZ3RoPDMmJihjPW8pO3ZhciBzPXVbMV08dVswXSxs
PXVbcy0wXSxmPXVbMS1zXSxoPShmLWwpLyhuLmxlbmd0aC1vKzIqYyk7cmV0dXJuIGk9cihsK2gq
YyxoKSxzJiZpLnJldmVyc2UoKSxhPWgqKDEtbyksdD17dDoicmFuZ2VCYW5kcyIsYTphcmd1bWVu
dHN9LGV9LGUucmFuZ2VSb3VuZEJhbmRzPWZ1bmN0aW9uKHUsbyxjKXthcmd1bWVudHMubGVuZ3Ro
PDImJihvPTApLGFyZ3VtZW50cy5sZW5ndGg8MyYmKGM9byk7dmFyIHM9dVsxXTx1WzBdLGw9dVtz
LTBdLGY9dVsxLXNdLGg9TWF0aC5mbG9vcigoZi1sKS8obi5sZW5ndGgtbysyKmMpKSxnPWYtbC0o
bi5sZW5ndGgtbykqaDtyZXR1cm4gaT1yKGwrTWF0aC5yb3VuZChnLzIpLGgpLHMmJmkucmV2ZXJz
ZSgpLGE9TWF0aC5yb3VuZChoKigxLW8pKSx0PXt0OiJyYW5nZVJvdW5kQmFuZHMiLGE6YXJndW1l
bnRzfSxlfSxlLnJhbmdlQmFuZD1mdW5jdGlvbigpe3JldHVybiBhfSxlLnJhbmdlRXh0ZW50PWZ1
bmN0aW9uKCl7cmV0dXJuIGppKHQuYVswXSl9LGUuY29weT1mdW5jdGlvbigpe3JldHVybiB0byhu
LHQpfSxlLmRvbWFpbihuKX1mdW5jdGlvbiBlbyhlLHIpe2Z1bmN0aW9uIHUoKXt2YXIgbj0wLHQ9
ci5sZW5ndGg7Zm9yKG89W107KytuPHQ7KW9bbi0xXT1Hby5xdWFudGlsZShlLG4vdCk7cmV0dXJu
IGl9ZnVuY3Rpb24gaShuKXtyZXR1cm4gaXNOYU4obj0rbik/dm9pZCAwOnJbR28uYmlzZWN0KG8s
bildfXZhciBvO3JldHVybiBpLmRvbWFpbj1mdW5jdGlvbihyKXtyZXR1cm4gYXJndW1lbnRzLmxl
bmd0aD8oZT1yLmZpbHRlcih0KS5zb3J0KG4pLHUoKSk6ZX0saS5yYW5nZT1mdW5jdGlvbihuKXty
ZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8ocj1uLHUoKSk6cn0saS5xdWFudGlsZXM9ZnVuY3Rpb24o
KXtyZXR1cm4gb30saS5pbnZlcnRFeHRlbnQ9ZnVuY3Rpb24obil7cmV0dXJuIG49ci5pbmRleE9m
KG4pLDA+bj9bMC8wLDAvMF06W24+MD9vW24tMV06ZVswXSxuPG8ubGVuZ3RoP29bbl06ZVtlLmxl
bmd0aC0xXV19LGkuY29weT1mdW5jdGlvbigpe3JldHVybiBlbyhlLHIpfSx1KCl9ZnVuY3Rpb24g
cm8obix0LGUpe2Z1bmN0aW9uIHIodCl7cmV0dXJuIGVbTWF0aC5tYXgoMCxNYXRoLm1pbihvLE1h
dGguZmxvb3IoaSoodC1uKSkpKV19ZnVuY3Rpb24gdSgpe3JldHVybiBpPWUubGVuZ3RoLyh0LW4p
LG89ZS5sZW5ndGgtMSxyfXZhciBpLG87cmV0dXJuIHIuZG9tYWluPWZ1bmN0aW9uKGUpe3JldHVy
biBhcmd1bWVudHMubGVuZ3RoPyhuPStlWzBdLHQ9K2VbZS5sZW5ndGgtMV0sdSgpKTpbbix0XX0s
ci5yYW5nZT1mdW5jdGlvbihuKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oZT1uLHUoKSk6ZX0s
ci5pbnZlcnRFeHRlbnQ9ZnVuY3Rpb24odCl7cmV0dXJuIHQ9ZS5pbmRleE9mKHQpLHQ9MD50PzAv
MDp0L2krbixbdCx0KzEvaV19LHIuY29weT1mdW5jdGlvbigpe3JldHVybiBybyhuLHQsZSl9LHUo
KX1mdW5jdGlvbiB1byhuLHQpe2Z1bmN0aW9uIGUoZSl7cmV0dXJuIGU+PWU/dFtHby5iaXNlY3Qo
bixlKV06dm9pZCAwfXJldHVybiBlLmRvbWFpbj1mdW5jdGlvbih0KXtyZXR1cm4gYXJndW1lbnRz
Lmxlbmd0aD8obj10LGUpOm59LGUucmFuZ2U9ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5s
ZW5ndGg/KHQ9bixlKTp0fSxlLmludmVydEV4dGVudD1mdW5jdGlvbihlKXtyZXR1cm4gZT10Lmlu
ZGV4T2YoZSksW25bZS0xXSxuW2VdXX0sZS5jb3B5PWZ1bmN0aW9uKCl7cmV0dXJuIHVvKG4sdCl9
LGV9ZnVuY3Rpb24gaW8obil7ZnVuY3Rpb24gdChuKXtyZXR1cm4rbn1yZXR1cm4gdC5pbnZlcnQ9
dCx0LmRvbWFpbj10LnJhbmdlPWZ1bmN0aW9uKGUpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhu
PWUubWFwKHQpLHQpOm59LHQudGlja3M9ZnVuY3Rpb24odCl7cmV0dXJuIEJpKG4sdCl9LHQudGlj
a0Zvcm1hdD1mdW5jdGlvbih0LGUpe3JldHVybiBKaShuLHQsZSl9LHQuY29weT1mdW5jdGlvbigp
e3JldHVybiBpbyhuKX0sdH1mdW5jdGlvbiBvbyhuKXtyZXR1cm4gbi5pbm5lclJhZGl1c31mdW5j
dGlvbiBhbyhuKXtyZXR1cm4gbi5vdXRlclJhZGl1c31mdW5jdGlvbiBjbyhuKXtyZXR1cm4gbi5z
dGFydEFuZ2xlfWZ1bmN0aW9uIHNvKG4pe3JldHVybiBuLmVuZEFuZ2xlfWZ1bmN0aW9uIGxvKG4p
e2Z1bmN0aW9uIHQodCl7ZnVuY3Rpb24gbygpe3MucHVzaCgiTSIsaShuKGwpLGEpKX1mb3IodmFy
IGMscz1bXSxsPVtdLGY9LTEsaD10Lmxlbmd0aCxnPUV0KGUpLHA9RXQocik7KytmPGg7KXUuY2Fs
bCh0aGlzLGM9dFtmXSxmKT9sLnB1c2goWytnLmNhbGwodGhpcyxjLGYpLCtwLmNhbGwodGhpcyxj
LGYpXSk6bC5sZW5ndGgmJihvKCksbD1bXSk7cmV0dXJuIGwubGVuZ3RoJiZvKCkscy5sZW5ndGg/
cy5qb2luKCIiKTpudWxsfXZhciBlPUFyLHI9Q3IsdT1BZSxpPWZvLG89aS5rZXksYT0uNztyZXR1
cm4gdC54PWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhlPW4sdCk6ZX0sdC55
PWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhyPW4sdCk6cn0sdC5kZWZpbmVk
PWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyh1PW4sdCk6dX0sdC5pbnRlcnBv
bGF0ZT1mdW5jdGlvbihuKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8obz0iZnVuY3Rpb24iPT10
eXBlb2Ygbj9pPW46KGk9a3MuZ2V0KG4pfHxmbykua2V5LHQpOm99LHQudGVuc2lvbj1mdW5jdGlv
bihuKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oYT1uLHQpOmF9LHR9ZnVuY3Rpb24gZm8obil7
cmV0dXJuIG4uam9pbigiTCIpfWZ1bmN0aW9uIGhvKG4pe3JldHVybiBmbyhuKSsiWiJ9ZnVuY3Rp
b24gZ28obil7Zm9yKHZhciB0PTAsZT1uLmxlbmd0aCxyPW5bMF0sdT1bclswXSwiLCIsclsxXV07
Kyt0PGU7KXUucHVzaCgiSCIsKHJbMF0rKHI9blt0XSlbMF0pLzIsIlYiLHJbMV0pO3JldHVybiBl
PjEmJnUucHVzaCgiSCIsclswXSksdS5qb2luKCIiKX1mdW5jdGlvbiBwbyhuKXtmb3IodmFyIHQ9
MCxlPW4ubGVuZ3RoLHI9blswXSx1PVtyWzBdLCIsIixyWzFdXTsrK3Q8ZTspdS5wdXNoKCJWIiwo
cj1uW3RdKVsxXSwiSCIsclswXSk7cmV0dXJuIHUuam9pbigiIil9ZnVuY3Rpb24gdm8obil7Zm9y
KHZhciB0PTAsZT1uLmxlbmd0aCxyPW5bMF0sdT1bclswXSwiLCIsclsxXV07Kyt0PGU7KXUucHVz
aCgiSCIsKHI9blt0XSlbMF0sIlYiLHJbMV0pO3JldHVybiB1LmpvaW4oIiIpfWZ1bmN0aW9uIG1v
KG4sdCl7cmV0dXJuIG4ubGVuZ3RoPDQ/Zm8obik6blsxXStNbyhuLnNsaWNlKDEsbi5sZW5ndGgt
MSksX28obix0KSl9ZnVuY3Rpb24geW8obix0KXtyZXR1cm4gbi5sZW5ndGg8Mz9mbyhuKTpuWzBd
K01vKChuLnB1c2goblswXSksbiksX28oW25bbi5sZW5ndGgtMl1dLmNvbmNhdChuLFtuWzFdXSks
dCkpfWZ1bmN0aW9uIHhvKG4sdCl7cmV0dXJuIG4ubGVuZ3RoPDM/Zm8obik6blswXStNbyhuLF9v
KG4sdCkpfWZ1bmN0aW9uIE1vKG4sdCl7aWYodC5sZW5ndGg8MXx8bi5sZW5ndGghPXQubGVuZ3Ro
JiZuLmxlbmd0aCE9dC5sZW5ndGgrMilyZXR1cm4gZm8obik7dmFyIGU9bi5sZW5ndGghPXQubGVu
Z3RoLHI9IiIsdT1uWzBdLGk9blsxXSxvPXRbMF0sYT1vLGM9MTtpZihlJiYocis9IlEiKyhpWzBd
LTIqb1swXS8zKSsiLCIrKGlbMV0tMipvWzFdLzMpKyIsIitpWzBdKyIsIitpWzFdLHU9blsxXSxj
PTIpLHQubGVuZ3RoPjEpe2E9dFsxXSxpPW5bY10sYysrLHIrPSJDIisodVswXStvWzBdKSsiLCIr
KHVbMV0rb1sxXSkrIiwiKyhpWzBdLWFbMF0pKyIsIisoaVsxXS1hWzFdKSsiLCIraVswXSsiLCIr
aVsxXTtmb3IodmFyIHM9MjtzPHQubGVuZ3RoO3MrKyxjKyspaT1uW2NdLGE9dFtzXSxyKz0iUyIr
KGlbMF0tYVswXSkrIiwiKyhpWzFdLWFbMV0pKyIsIitpWzBdKyIsIitpWzFdfWlmKGUpe3ZhciBs
PW5bY107cis9IlEiKyhpWzBdKzIqYVswXS8zKSsiLCIrKGlbMV0rMiphWzFdLzMpKyIsIitsWzBd
KyIsIitsWzFdfXJldHVybiByfWZ1bmN0aW9uIF9vKG4sdCl7Zm9yKHZhciBlLHI9W10sdT0oMS10
KS8yLGk9blswXSxvPW5bMV0sYT0xLGM9bi5sZW5ndGg7KythPGM7KWU9aSxpPW8sbz1uW2FdLHIu
cHVzaChbdSoob1swXS1lWzBdKSx1KihvWzFdLWVbMV0pXSk7cmV0dXJuIHJ9ZnVuY3Rpb24gYm8o
bil7aWYobi5sZW5ndGg8MylyZXR1cm4gZm8obik7dmFyIHQ9MSxlPW4ubGVuZ3RoLHI9blswXSx1
PXJbMF0saT1yWzFdLG89W3UsdSx1LChyPW5bMV0pWzBdXSxhPVtpLGksaSxyWzFdXSxjPVt1LCIs
IixpLCJMIixFbyhDcyxvKSwiLCIsRW8oQ3MsYSldO2ZvcihuLnB1c2gobltlLTFdKTsrK3Q8PWU7
KXI9blt0XSxvLnNoaWZ0KCksby5wdXNoKHJbMF0pLGEuc2hpZnQoKSxhLnB1c2goclsxXSksQW8o
YyxvLGEpO3JldHVybiBuLnBvcCgpLGMucHVzaCgiTCIsciksYy5qb2luKCIiKX1mdW5jdGlvbiB3
byhuKXtpZihuLmxlbmd0aDw0KXJldHVybiBmbyhuKTtmb3IodmFyIHQsZT1bXSxyPS0xLHU9bi5s
ZW5ndGgsaT1bMF0sbz1bMF07KytyPDM7KXQ9bltyXSxpLnB1c2godFswXSksby5wdXNoKHRbMV0p
O2ZvcihlLnB1c2goRW8oQ3MsaSkrIiwiK0VvKENzLG8pKSwtLXI7KytyPHU7KXQ9bltyXSxpLnNo
aWZ0KCksaS5wdXNoKHRbMF0pLG8uc2hpZnQoKSxvLnB1c2godFsxXSksQW8oZSxpLG8pO3JldHVy
biBlLmpvaW4oIiIpfWZ1bmN0aW9uIFNvKG4pe2Zvcih2YXIgdCxlLHI9LTEsdT1uLmxlbmd0aCxp
PXUrNCxvPVtdLGE9W107KytyPDQ7KWU9bltyJXVdLG8ucHVzaChlWzBdKSxhLnB1c2goZVsxXSk7
Zm9yKHQ9W0VvKENzLG8pLCIsIixFbyhDcyxhKV0sLS1yOysrcjxpOyllPW5bciV1XSxvLnNoaWZ0
KCksby5wdXNoKGVbMF0pLGEuc2hpZnQoKSxhLnB1c2goZVsxXSksQW8odCxvLGEpO3JldHVybiB0
LmpvaW4oIiIpfWZ1bmN0aW9uIGtvKG4sdCl7dmFyIGU9bi5sZW5ndGgtMTtpZihlKWZvcih2YXIg
cix1LGk9blswXVswXSxvPW5bMF1bMV0sYT1uW2VdWzBdLWksYz1uW2VdWzFdLW8scz0tMTsrK3M8
PWU7KXI9bltzXSx1PXMvZSxyWzBdPXQqclswXSsoMS10KSooaSt1KmEpLHJbMV09dCpyWzFdKygx
LXQpKihvK3UqYyk7cmV0dXJuIGJvKG4pfWZ1bmN0aW9uIEVvKG4sdCl7cmV0dXJuIG5bMF0qdFsw
XStuWzFdKnRbMV0rblsyXSp0WzJdK25bM10qdFszXX1mdW5jdGlvbiBBbyhuLHQsZSl7bi5wdXNo
KCJDIixFbyhFcyx0KSwiLCIsRW8oRXMsZSksIiwiLEVvKEFzLHQpLCIsIixFbyhBcyxlKSwiLCIs
RW8oQ3MsdCksIiwiLEVvKENzLGUpKX1mdW5jdGlvbiBDbyhuLHQpe3JldHVybih0WzFdLW5bMV0p
Lyh0WzBdLW5bMF0pfWZ1bmN0aW9uIE5vKG4pe2Zvcih2YXIgdD0wLGU9bi5sZW5ndGgtMSxyPVtd
LHU9blswXSxpPW5bMV0sbz1yWzBdPUNvKHUsaSk7Kyt0PGU7KXJbdF09KG8rKG89Q28odT1pLGk9
blt0KzFdKSkpLzI7cmV0dXJuIHJbdF09byxyfWZ1bmN0aW9uIExvKG4pe2Zvcih2YXIgdCxlLHIs
dSxpPVtdLG89Tm8obiksYT0tMSxjPW4ubGVuZ3RoLTE7KythPGM7KXQ9Q28oblthXSxuW2ErMV0p
LGZhKHQpPFRhP29bYV09b1thKzFdPTA6KGU9b1thXS90LHI9b1thKzFdL3QsdT1lKmUrcipyLHU+
OSYmKHU9Myp0L01hdGguc3FydCh1KSxvW2FdPXUqZSxvW2ErMV09dSpyKSk7Zm9yKGE9LTE7Kyth
PD1jOyl1PShuW01hdGgubWluKGMsYSsxKV1bMF0tbltNYXRoLm1heCgwLGEtMSldWzBdKS8oNioo
MStvW2FdKm9bYV0pKSxpLnB1c2goW3V8fDAsb1thXSp1fHwwXSk7cmV0dXJuIGl9ZnVuY3Rpb24g
VG8obil7cmV0dXJuIG4ubGVuZ3RoPDM/Zm8obik6blswXStNbyhuLExvKG4pKX1mdW5jdGlvbiBx
byhuKXtmb3IodmFyIHQsZSxyLHU9LTEsaT1uLmxlbmd0aDsrK3U8aTspdD1uW3VdLGU9dFswXSxy
PXRbMV0rd3MsdFswXT1lKk1hdGguY29zKHIpLHRbMV09ZSpNYXRoLnNpbihyKTtyZXR1cm4gbn1m
dW5jdGlvbiB6byhuKXtmdW5jdGlvbiB0KHQpe2Z1bmN0aW9uIGMoKXt2LnB1c2goIk0iLGEobiht
KSxmKSxsLHMobihkLnJldmVyc2UoKSksZiksIloiKX1mb3IodmFyIGgsZyxwLHY9W10sZD1bXSxt
PVtdLHk9LTEseD10Lmxlbmd0aCxNPUV0KGUpLF89RXQodSksYj1lPT09cj9mdW5jdGlvbigpe3Jl
dHVybiBnfTpFdChyKSx3PXU9PT1pP2Z1bmN0aW9uKCl7cmV0dXJuIHB9OkV0KGkpOysreTx4Oylv
LmNhbGwodGhpcyxoPXRbeV0seSk/KGQucHVzaChbZz0rTS5jYWxsKHRoaXMsaCx5KSxwPStfLmNh
bGwodGhpcyxoLHkpXSksbS5wdXNoKFsrYi5jYWxsKHRoaXMsaCx5KSwrdy5jYWxsKHRoaXMsaCx5
KV0pKTpkLmxlbmd0aCYmKGMoKSxkPVtdLG09W10pO3JldHVybiBkLmxlbmd0aCYmYygpLHYubGVu
Z3RoP3Yuam9pbigiIik6bnVsbH12YXIgZT1BcixyPUFyLHU9MCxpPUNyLG89QWUsYT1mbyxjPWEu
a2V5LHM9YSxsPSJMIixmPS43O3JldHVybiB0Lng9ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50
cy5sZW5ndGg/KGU9cj1uLHQpOnJ9LHQueDA9ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5s
ZW5ndGg/KGU9bix0KTplfSx0LngxPWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3Ro
PyhyPW4sdCk6cn0sdC55PWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyh1PWk9
bix0KTppfSx0LnkwPWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyh1PW4sdCk6
dX0sdC55MT1mdW5jdGlvbihuKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oaT1uLHQpOml9LHQu
ZGVmaW5lZD1mdW5jdGlvbihuKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8obz1uLHQpOm99LHQu
aW50ZXJwb2xhdGU9ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KGM9ImZ1bmN0
aW9uIj09dHlwZW9mIG4/YT1uOihhPWtzLmdldChuKXx8Zm8pLmtleSxzPWEucmV2ZXJzZXx8YSxs
PWEuY2xvc2VkPyJNIjoiTCIsdCk6Y30sdC50ZW5zaW9uPWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1
bWVudHMubGVuZ3RoPyhmPW4sdCk6Zn0sdH1mdW5jdGlvbiBSbyhuKXtyZXR1cm4gbi5yYWRpdXN9
ZnVuY3Rpb24gRG8obil7cmV0dXJuW24ueCxuLnldfWZ1bmN0aW9uIFBvKG4pe3JldHVybiBmdW5j
dGlvbigpe3ZhciB0PW4uYXBwbHkodGhpcyxhcmd1bWVudHMpLGU9dFswXSxyPXRbMV0rd3M7cmV0
dXJuW2UqTWF0aC5jb3MociksZSpNYXRoLnNpbihyKV19fWZ1bmN0aW9uIFVvKCl7cmV0dXJuIDY0
fWZ1bmN0aW9uIGpvKCl7cmV0dXJuImNpcmNsZSJ9ZnVuY3Rpb24gSG8obil7dmFyIHQ9TWF0aC5z
cXJ0KG4vQ2EpO3JldHVybiJNMCwiK3QrIkEiK3QrIiwiK3QrIiAwIDEsMSAwLCIrLXQrIkEiK3Qr
IiwiK3QrIiAwIDEsMSAwLCIrdCsiWiJ9ZnVuY3Rpb24gRm8obix0KXtyZXR1cm4gZGEobixScyks
bi5pZD10LG59ZnVuY3Rpb24gT28obix0LGUscil7dmFyIHU9bi5pZDtyZXR1cm4gUChuLCJmdW5j
dGlvbiI9PXR5cGVvZiBlP2Z1bmN0aW9uKG4saSxvKXtuLl9fdHJhbnNpdGlvbl9fW3VdLnR3ZWVu
LnNldCh0LHIoZS5jYWxsKG4sbi5fX2RhdGFfXyxpLG8pKSl9OihlPXIoZSksZnVuY3Rpb24obil7
bi5fX3RyYW5zaXRpb25fX1t1XS50d2Vlbi5zZXQodCxlKX0pKX1mdW5jdGlvbiBJbyhuKXtyZXR1
cm4gbnVsbD09biYmKG49IiIpLGZ1bmN0aW9uKCl7dGhpcy50ZXh0Q29udGVudD1ufX1mdW5jdGlv
biBZbyhuLHQsZSxyKXt2YXIgdT1uLl9fdHJhbnNpdGlvbl9ffHwobi5fX3RyYW5zaXRpb25fXz17
YWN0aXZlOjAsY291bnQ6MH0pLGk9dVtlXTtpZighaSl7dmFyIGE9ci50aW1lO2k9dVtlXT17dHdl
ZW46bmV3IG8sdGltZTphLGVhc2U6ci5lYXNlLGRlbGF5OnIuZGVsYXksZHVyYXRpb246ci5kdXJh
dGlvbn0sKyt1LmNvdW50LEdvLnRpbWVyKGZ1bmN0aW9uKHIpe2Z1bmN0aW9uIG8ocil7cmV0dXJu
IHUuYWN0aXZlPmU/cygpOih1LmFjdGl2ZT1lLGkuZXZlbnQmJmkuZXZlbnQuc3RhcnQuY2FsbChu
LGwsdCksaS50d2Vlbi5mb3JFYWNoKGZ1bmN0aW9uKGUscil7KHI9ci5jYWxsKG4sbCx0KSkmJnYu
cHVzaChyKX0pLEdvLnRpbWVyKGZ1bmN0aW9uKCl7cmV0dXJuIHAuYz1jKHJ8fDEpP0FlOmMsMX0s
MCxhKSx2b2lkIDApfWZ1bmN0aW9uIGMocil7aWYodS5hY3RpdmUhPT1lKXJldHVybiBzKCk7Zm9y
KHZhciBvPXIvZyxhPWYobyksYz12Lmxlbmd0aDtjPjA7KXZbLS1jXS5jYWxsKG4sYSk7cmV0dXJu
IG8+PTE/KGkuZXZlbnQmJmkuZXZlbnQuZW5kLmNhbGwobixsLHQpLHMoKSk6dm9pZCAwfWZ1bmN0
aW9uIHMoKXtyZXR1cm4tLXUuY291bnQ/ZGVsZXRlIHVbZV06ZGVsZXRlIG4uX190cmFuc2l0aW9u
X18sMX12YXIgbD1uLl9fZGF0YV9fLGY9aS5lYXNlLGg9aS5kZWxheSxnPWkuZHVyYXRpb24scD1u
Yyx2PVtdO3JldHVybiBwLnQ9aCthLHI+PWg/byhyLWgpOihwLmM9byx2b2lkIDApfSwwLGEpfX1m
dW5jdGlvbiBabyhuLHQpe24uYXR0cigidHJhbnNmb3JtIixmdW5jdGlvbihuKXtyZXR1cm4idHJh
bnNsYXRlKCIrdChuKSsiLDApIn0pfWZ1bmN0aW9uIFZvKG4sdCl7bi5hdHRyKCJ0cmFuc2Zvcm0i
LGZ1bmN0aW9uKG4pe3JldHVybiJ0cmFuc2xhdGUoMCwiK3QobikrIikifSl9ZnVuY3Rpb24gJG8o
bil7cmV0dXJuIG4udG9JU09TdHJpbmcoKX1mdW5jdGlvbiBYbyhuLHQsZSl7ZnVuY3Rpb24gcih0
KXtyZXR1cm4gbih0KQp9ZnVuY3Rpb24gdShuLGUpe3ZhciByPW5bMV0tblswXSx1PXIvZSxpPUdv
LmJpc2VjdChZcyx1KTtyZXR1cm4gaT09WXMubGVuZ3RoP1t0LnllYXIsWGkobi5tYXAoZnVuY3Rp
b24obil7cmV0dXJuIG4vMzE1MzZlNn0pLGUpWzJdXTppP3RbdS9Zc1tpLTFdPFlzW2ldL3U/aS0x
OmldOlskcyxYaShuLGUpWzJdXX1yZXR1cm4gci5pbnZlcnQ9ZnVuY3Rpb24odCl7cmV0dXJuIEJv
KG4uaW52ZXJ0KHQpKX0sci5kb21haW49ZnVuY3Rpb24odCl7cmV0dXJuIGFyZ3VtZW50cy5sZW5n
dGg/KG4uZG9tYWluKHQpLHIpOm4uZG9tYWluKCkubWFwKEJvKX0sci5uaWNlPWZ1bmN0aW9uKG4s
dCl7ZnVuY3Rpb24gZShlKXtyZXR1cm4haXNOYU4oZSkmJiFuLnJhbmdlKGUsQm8oK2UrMSksdCku
bGVuZ3RofXZhciBpPXIuZG9tYWluKCksbz1qaShpKSxhPW51bGw9PW4/dShvLDEwKToibnVtYmVy
Ij09dHlwZW9mIG4mJnUobyxuKTtyZXR1cm4gYSYmKG49YVswXSx0PWFbMV0pLHIuZG9tYWluKE9p
KGksdD4xP3tmbG9vcjpmdW5jdGlvbih0KXtmb3IoO2UodD1uLmZsb29yKHQpKTspdD1Cbyh0LTEp
O3JldHVybiB0fSxjZWlsOmZ1bmN0aW9uKHQpe2Zvcig7ZSh0PW4uY2VpbCh0KSk7KXQ9Qm8oK3Qr
MSk7cmV0dXJuIHR9fTpuKSl9LHIudGlja3M9ZnVuY3Rpb24obix0KXt2YXIgZT1qaShyLmRvbWFp
bigpKSxpPW51bGw9PW4/dShlLDEwKToibnVtYmVyIj09dHlwZW9mIG4/dShlLG4pOiFuLnJhbmdl
JiZbe3JhbmdlOm59LHRdO3JldHVybiBpJiYobj1pWzBdLHQ9aVsxXSksbi5yYW5nZShlWzBdLEJv
KCtlWzFdKzEpLDE+dD8xOnQpfSxyLnRpY2tGb3JtYXQ9ZnVuY3Rpb24oKXtyZXR1cm4gZX0sci5j
b3B5PWZ1bmN0aW9uKCl7cmV0dXJuIFhvKG4uY29weSgpLHQsZSl9LFZpKHIsbil9ZnVuY3Rpb24g
Qm8obil7cmV0dXJuIG5ldyBEYXRlKG4pfWZ1bmN0aW9uIEpvKG4pe3JldHVybiBKU09OLnBhcnNl
KG4ucmVzcG9uc2VUZXh0KX1mdW5jdGlvbiBXbyhuKXt2YXIgdD1uYS5jcmVhdGVSYW5nZSgpO3Jl
dHVybiB0LnNlbGVjdE5vZGUobmEuYm9keSksdC5jcmVhdGVDb250ZXh0dWFsRnJhZ21lbnQobi5y
ZXNwb25zZVRleHQpfXZhciBHbz17dmVyc2lvbjoiMy40LjYifTtEYXRlLm5vd3x8KERhdGUubm93
PWZ1bmN0aW9uKCl7cmV0dXJuK25ldyBEYXRlfSk7dmFyIEtvPVtdLnNsaWNlLFFvPWZ1bmN0aW9u
KG4pe3JldHVybiBLby5jYWxsKG4pfSxuYT1kb2N1bWVudCx0YT1uYS5kb2N1bWVudEVsZW1lbnQs
ZWE9d2luZG93O3RyeXtRbyh0YS5jaGlsZE5vZGVzKVswXS5ub2RlVHlwZX1jYXRjaChyYSl7UW89
ZnVuY3Rpb24obil7Zm9yKHZhciB0PW4ubGVuZ3RoLGU9bmV3IEFycmF5KHQpO3QtLTspZVt0XT1u
W3RdO3JldHVybiBlfX10cnl7bmEuY3JlYXRlRWxlbWVudCgiZGl2Iikuc3R5bGUuc2V0UHJvcGVy
dHkoIm9wYWNpdHkiLDAsIiIpfWNhdGNoKHVhKXt2YXIgaWE9ZWEuRWxlbWVudC5wcm90b3R5cGUs
b2E9aWEuc2V0QXR0cmlidXRlLGFhPWlhLnNldEF0dHJpYnV0ZU5TLGNhPWVhLkNTU1N0eWxlRGVj
bGFyYXRpb24ucHJvdG90eXBlLHNhPWNhLnNldFByb3BlcnR5O2lhLnNldEF0dHJpYnV0ZT1mdW5j
dGlvbihuLHQpe29hLmNhbGwodGhpcyxuLHQrIiIpfSxpYS5zZXRBdHRyaWJ1dGVOUz1mdW5jdGlv
bihuLHQsZSl7YWEuY2FsbCh0aGlzLG4sdCxlKyIiKX0sY2Euc2V0UHJvcGVydHk9ZnVuY3Rpb24o
bix0LGUpe3NhLmNhbGwodGhpcyxuLHQrIiIsZSl9fUdvLmFzY2VuZGluZz1uLEdvLmRlc2NlbmRp
bmc9ZnVuY3Rpb24obix0KXtyZXR1cm4gbj50Py0xOnQ+bj8xOnQ+PW4/MDowLzB9LEdvLm1pbj1m
dW5jdGlvbihuLHQpe3ZhciBlLHIsdT0tMSxpPW4ubGVuZ3RoO2lmKDE9PT1hcmd1bWVudHMubGVu
Z3RoKXtmb3IoOysrdTxpJiYhKG51bGwhPShlPW5bdV0pJiZlPj1lKTspZT12b2lkIDA7Zm9yKDsr
K3U8aTspbnVsbCE9KHI9blt1XSkmJmU+ciYmKGU9cil9ZWxzZXtmb3IoOysrdTxpJiYhKG51bGwh
PShlPXQuY2FsbChuLG5bdV0sdSkpJiZlPj1lKTspZT12b2lkIDA7Zm9yKDsrK3U8aTspbnVsbCE9
KHI9dC5jYWxsKG4sblt1XSx1KSkmJmU+ciYmKGU9cil9cmV0dXJuIGV9LEdvLm1heD1mdW5jdGlv
bihuLHQpe3ZhciBlLHIsdT0tMSxpPW4ubGVuZ3RoO2lmKDE9PT1hcmd1bWVudHMubGVuZ3RoKXtm
b3IoOysrdTxpJiYhKG51bGwhPShlPW5bdV0pJiZlPj1lKTspZT12b2lkIDA7Zm9yKDsrK3U8aTsp
bnVsbCE9KHI9blt1XSkmJnI+ZSYmKGU9cil9ZWxzZXtmb3IoOysrdTxpJiYhKG51bGwhPShlPXQu
Y2FsbChuLG5bdV0sdSkpJiZlPj1lKTspZT12b2lkIDA7Zm9yKDsrK3U8aTspbnVsbCE9KHI9dC5j
YWxsKG4sblt1XSx1KSkmJnI+ZSYmKGU9cil9cmV0dXJuIGV9LEdvLmV4dGVudD1mdW5jdGlvbihu
LHQpe3ZhciBlLHIsdSxpPS0xLG89bi5sZW5ndGg7aWYoMT09PWFyZ3VtZW50cy5sZW5ndGgpe2Zv
cig7KytpPG8mJiEobnVsbCE9KGU9dT1uW2ldKSYmZT49ZSk7KWU9dT12b2lkIDA7Zm9yKDsrK2k8
bzspbnVsbCE9KHI9bltpXSkmJihlPnImJihlPXIpLHI+dSYmKHU9cikpfWVsc2V7Zm9yKDsrK2k8
byYmIShudWxsIT0oZT11PXQuY2FsbChuLG5baV0saSkpJiZlPj1lKTspZT12b2lkIDA7Zm9yKDsr
K2k8bzspbnVsbCE9KHI9dC5jYWxsKG4sbltpXSxpKSkmJihlPnImJihlPXIpLHI+dSYmKHU9cikp
fXJldHVybltlLHVdfSxHby5zdW09ZnVuY3Rpb24obix0KXt2YXIgZSxyPTAsdT1uLmxlbmd0aCxp
PS0xO2lmKDE9PT1hcmd1bWVudHMubGVuZ3RoKWZvcig7KytpPHU7KWlzTmFOKGU9K25baV0pfHwo
cis9ZSk7ZWxzZSBmb3IoOysraTx1Oylpc05hTihlPSt0LmNhbGwobixuW2ldLGkpKXx8KHIrPWUp
O3JldHVybiByfSxHby5tZWFuPWZ1bmN0aW9uKG4sZSl7dmFyIHIsdT0wLGk9bi5sZW5ndGgsbz0t
MSxhPWk7aWYoMT09PWFyZ3VtZW50cy5sZW5ndGgpZm9yKDsrK288aTspdChyPW5bb10pP3UrPXI6
LS1hO2Vsc2UgZm9yKDsrK288aTspdChyPWUuY2FsbChuLG5bb10sbykpP3UrPXI6LS1hO3JldHVy
biBhP3UvYTp2b2lkIDB9LEdvLnF1YW50aWxlPWZ1bmN0aW9uKG4sdCl7dmFyIGU9KG4ubGVuZ3Ro
LTEpKnQrMSxyPU1hdGguZmxvb3IoZSksdT0rbltyLTFdLGk9ZS1yO3JldHVybiBpP3UraSooblty
XS11KTp1fSxHby5tZWRpYW49ZnVuY3Rpb24oZSxyKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD4x
JiYoZT1lLm1hcChyKSksZT1lLmZpbHRlcih0KSxlLmxlbmd0aD9Hby5xdWFudGlsZShlLnNvcnQo
biksLjUpOnZvaWQgMH07dmFyIGxhPWUobik7R28uYmlzZWN0TGVmdD1sYS5sZWZ0LEdvLmJpc2Vj
dD1Hby5iaXNlY3RSaWdodD1sYS5yaWdodCxHby5iaXNlY3Rvcj1mdW5jdGlvbih0KXtyZXR1cm4g
ZSgxPT09dC5sZW5ndGg/ZnVuY3Rpb24oZSxyKXtyZXR1cm4gbih0KGUpLHIpfTp0KX0sR28uc2h1
ZmZsZT1mdW5jdGlvbihuKXtmb3IodmFyIHQsZSxyPW4ubGVuZ3RoO3I7KWU9MHxNYXRoLnJhbmRv
bSgpKnItLSx0PW5bcl0sbltyXT1uW2VdLG5bZV09dDtyZXR1cm4gbn0sR28ucGVybXV0ZT1mdW5j
dGlvbihuLHQpe2Zvcih2YXIgZT10Lmxlbmd0aCxyPW5ldyBBcnJheShlKTtlLS07KXJbZV09blt0
W2VdXTtyZXR1cm4gcn0sR28ucGFpcnM9ZnVuY3Rpb24obil7Zm9yKHZhciB0LGU9MCxyPW4ubGVu
Z3RoLTEsdT1uWzBdLGk9bmV3IEFycmF5KDA+cj8wOnIpO3I+ZTspaVtlXT1bdD11LHU9blsrK2Vd
XTtyZXR1cm4gaX0sR28uemlwPWZ1bmN0aW9uKCl7aWYoISh1PWFyZ3VtZW50cy5sZW5ndGgpKXJl
dHVybltdO2Zvcih2YXIgbj0tMSx0PUdvLm1pbihhcmd1bWVudHMsciksZT1uZXcgQXJyYXkodCk7
KytuPHQ7KWZvcih2YXIgdSxpPS0xLG89ZVtuXT1uZXcgQXJyYXkodSk7KytpPHU7KW9baV09YXJn
dW1lbnRzW2ldW25dO3JldHVybiBlfSxHby50cmFuc3Bvc2U9ZnVuY3Rpb24obil7cmV0dXJuIEdv
LnppcC5hcHBseShHbyxuKX0sR28ua2V5cz1mdW5jdGlvbihuKXt2YXIgdD1bXTtmb3IodmFyIGUg
aW4gbil0LnB1c2goZSk7cmV0dXJuIHR9LEdvLnZhbHVlcz1mdW5jdGlvbihuKXt2YXIgdD1bXTtm
b3IodmFyIGUgaW4gbil0LnB1c2gobltlXSk7cmV0dXJuIHR9LEdvLmVudHJpZXM9ZnVuY3Rpb24o
bil7dmFyIHQ9W107Zm9yKHZhciBlIGluIG4pdC5wdXNoKHtrZXk6ZSx2YWx1ZTpuW2VdfSk7cmV0
dXJuIHR9LEdvLm1lcmdlPWZ1bmN0aW9uKG4pe2Zvcih2YXIgdCxlLHIsdT1uLmxlbmd0aCxpPS0x
LG89MDsrK2k8dTspbys9bltpXS5sZW5ndGg7Zm9yKGU9bmV3IEFycmF5KG8pOy0tdT49MDspZm9y
KHI9blt1XSx0PXIubGVuZ3RoOy0tdD49MDspZVstLW9dPXJbdF07cmV0dXJuIGV9O3ZhciBmYT1N
YXRoLmFicztHby5yYW5nZT1mdW5jdGlvbihuLHQsZSl7aWYoYXJndW1lbnRzLmxlbmd0aDwzJiYo
ZT0xLGFyZ3VtZW50cy5sZW5ndGg8MiYmKHQ9bixuPTApKSwxLzA9PT0odC1uKS9lKXRocm93IG5l
dyBFcnJvcigiaW5maW5pdGUgcmFuZ2UiKTt2YXIgcixpPVtdLG89dShmYShlKSksYT0tMTtpZihu
Kj1vLHQqPW8sZSo9bywwPmUpZm9yKDsocj1uK2UqKythKT50OylpLnB1c2goci9vKTtlbHNlIGZv
cig7KHI9bitlKisrYSk8dDspaS5wdXNoKHIvbyk7cmV0dXJuIGl9LEdvLm1hcD1mdW5jdGlvbihu
KXt2YXIgdD1uZXcgbztpZihuIGluc3RhbmNlb2YgbyluLmZvckVhY2goZnVuY3Rpb24obixlKXt0
LnNldChuLGUpfSk7ZWxzZSBmb3IodmFyIGUgaW4gbil0LnNldChlLG5bZV0pO3JldHVybiB0fSxp
KG8se2hhczphLGdldDpmdW5jdGlvbihuKXtyZXR1cm4gdGhpc1toYStuXX0sc2V0OmZ1bmN0aW9u
KG4sdCl7cmV0dXJuIHRoaXNbaGErbl09dH0scmVtb3ZlOmMsa2V5czpzLHZhbHVlczpmdW5jdGlv
bigpe3ZhciBuPVtdO3JldHVybiB0aGlzLmZvckVhY2goZnVuY3Rpb24odCxlKXtuLnB1c2goZSl9
KSxufSxlbnRyaWVzOmZ1bmN0aW9uKCl7dmFyIG49W107cmV0dXJuIHRoaXMuZm9yRWFjaChmdW5j
dGlvbih0LGUpe24ucHVzaCh7a2V5OnQsdmFsdWU6ZX0pfSksbn0sc2l6ZTpsLGVtcHR5OmYsZm9y
RWFjaDpmdW5jdGlvbihuKXtmb3IodmFyIHQgaW4gdGhpcyl0LmNoYXJDb2RlQXQoMCk9PT1nYSYm
bi5jYWxsKHRoaXMsdC5zdWJzdHJpbmcoMSksdGhpc1t0XSl9fSk7dmFyIGhhPSJceDAwIixnYT1o
YS5jaGFyQ29kZUF0KDApO0dvLm5lc3Q9ZnVuY3Rpb24oKXtmdW5jdGlvbiBuKHQsYSxjKXtpZihj
Pj1pLmxlbmd0aClyZXR1cm4gcj9yLmNhbGwodSxhKTplP2Euc29ydChlKTphO2Zvcih2YXIgcyxs
LGYsaCxnPS0xLHA9YS5sZW5ndGgsdj1pW2MrK10sZD1uZXcgbzsrK2c8cDspKGg9ZC5nZXQocz12
KGw9YVtnXSkpKT9oLnB1c2gobCk6ZC5zZXQocyxbbF0pO3JldHVybiB0PyhsPXQoKSxmPWZ1bmN0
aW9uKGUscil7bC5zZXQoZSxuKHQscixjKSl9KToobD17fSxmPWZ1bmN0aW9uKGUscil7bFtlXT1u
KHQscixjKX0pLGQuZm9yRWFjaChmKSxsfWZ1bmN0aW9uIHQobixlKXtpZihlPj1pLmxlbmd0aCly
ZXR1cm4gbjt2YXIgcj1bXSx1PWFbZSsrXTtyZXR1cm4gbi5mb3JFYWNoKGZ1bmN0aW9uKG4sdSl7
ci5wdXNoKHtrZXk6bix2YWx1ZXM6dCh1LGUpfSl9KSx1P3Iuc29ydChmdW5jdGlvbihuLHQpe3Jl
dHVybiB1KG4ua2V5LHQua2V5KX0pOnJ9dmFyIGUscix1PXt9LGk9W10sYT1bXTtyZXR1cm4gdS5t
YXA9ZnVuY3Rpb24odCxlKXtyZXR1cm4gbihlLHQsMCl9LHUuZW50cmllcz1mdW5jdGlvbihlKXty
ZXR1cm4gdChuKEdvLm1hcCxlLDApLDApfSx1LmtleT1mdW5jdGlvbihuKXtyZXR1cm4gaS5wdXNo
KG4pLHV9LHUuc29ydEtleXM9ZnVuY3Rpb24obil7cmV0dXJuIGFbaS5sZW5ndGgtMV09bix1fSx1
LnNvcnRWYWx1ZXM9ZnVuY3Rpb24obil7cmV0dXJuIGU9bix1fSx1LnJvbGx1cD1mdW5jdGlvbihu
KXtyZXR1cm4gcj1uLHV9LHV9LEdvLnNldD1mdW5jdGlvbihuKXt2YXIgdD1uZXcgaDtpZihuKWZv
cih2YXIgZT0wLHI9bi5sZW5ndGg7cj5lOysrZSl0LmFkZChuW2VdKTtyZXR1cm4gdH0saShoLHto
YXM6YSxhZGQ6ZnVuY3Rpb24obil7cmV0dXJuIHRoaXNbaGErbl09ITAsbn0scmVtb3ZlOmZ1bmN0
aW9uKG4pe3JldHVybiBuPWhhK24sbiBpbiB0aGlzJiZkZWxldGUgdGhpc1tuXX0sdmFsdWVzOnMs
c2l6ZTpsLGVtcHR5OmYsZm9yRWFjaDpmdW5jdGlvbihuKXtmb3IodmFyIHQgaW4gdGhpcyl0LmNo
YXJDb2RlQXQoMCk9PT1nYSYmbi5jYWxsKHRoaXMsdC5zdWJzdHJpbmcoMSkpfX0pLEdvLmJlaGF2
aW9yPXt9LEdvLnJlYmluZD1mdW5jdGlvbihuLHQpe2Zvcih2YXIgZSxyPTEsdT1hcmd1bWVudHMu
bGVuZ3RoOysrcjx1OyluW2U9YXJndW1lbnRzW3JdXT1nKG4sdCx0W2VdKTtyZXR1cm4gbn07dmFy
IHBhPVsid2Via2l0IiwibXMiLCJtb3oiLCJNb3oiLCJvIiwiTyJdO0dvLmRpc3BhdGNoPWZ1bmN0
aW9uKCl7Zm9yKHZhciBuPW5ldyBkLHQ9LTEsZT1hcmd1bWVudHMubGVuZ3RoOysrdDxlOyluW2Fy
Z3VtZW50c1t0XV09bShuKTtyZXR1cm4gbn0sZC5wcm90b3R5cGUub249ZnVuY3Rpb24obix0KXt2
YXIgZT1uLmluZGV4T2YoIi4iKSxyPSIiO2lmKGU+PTAmJihyPW4uc3Vic3RyaW5nKGUrMSksbj1u
LnN1YnN0cmluZygwLGUpKSxuKXJldHVybiBhcmd1bWVudHMubGVuZ3RoPDI/dGhpc1tuXS5vbihy
KTp0aGlzW25dLm9uKHIsdCk7aWYoMj09PWFyZ3VtZW50cy5sZW5ndGgpe2lmKG51bGw9PXQpZm9y
KG4gaW4gdGhpcyl0aGlzLmhhc093blByb3BlcnR5KG4pJiZ0aGlzW25dLm9uKHIsbnVsbCk7cmV0
dXJuIHRoaXN9fSxHby5ldmVudD1udWxsLEdvLnJlcXVvdGU9ZnVuY3Rpb24obil7cmV0dXJuIG4u
cmVwbGFjZSh2YSwiXFwkJiIpfTt2YXIgdmE9L1tcXFxeXCRcKlwrXD9cfFxbXF1cKFwpXC5ce1x9
XS9nLGRhPXt9Ll9fcHJvdG9fXz9mdW5jdGlvbihuLHQpe24uX19wcm90b19fPXR9OmZ1bmN0aW9u
KG4sdCl7Zm9yKHZhciBlIGluIHQpbltlXT10W2VdfSxtYT1mdW5jdGlvbihuLHQpe3JldHVybiB0
LnF1ZXJ5U2VsZWN0b3Iobil9LHlhPWZ1bmN0aW9uKG4sdCl7cmV0dXJuIHQucXVlcnlTZWxlY3Rv
ckFsbChuKX0seGE9dGFbcCh0YSwibWF0Y2hlc1NlbGVjdG9yIildLE1hPWZ1bmN0aW9uKG4sdCl7
cmV0dXJuIHhhLmNhbGwobix0KX07ImZ1bmN0aW9uIj09dHlwZW9mIFNpenpsZSYmKG1hPWZ1bmN0
aW9uKG4sdCl7cmV0dXJuIFNpenpsZShuLHQpWzBdfHxudWxsfSx5YT1TaXp6bGUsTWE9U2l6emxl
Lm1hdGNoZXNTZWxlY3RvciksR28uc2VsZWN0aW9uPWZ1bmN0aW9uKCl7cmV0dXJuIFNhfTt2YXIg
X2E9R28uc2VsZWN0aW9uLnByb3RvdHlwZT1bXTtfYS5zZWxlY3Q9ZnVuY3Rpb24obil7dmFyIHQs
ZSxyLHUsaT1bXTtuPWIobik7Zm9yKHZhciBvPS0xLGE9dGhpcy5sZW5ndGg7KytvPGE7KXtpLnB1
c2godD1bXSksdC5wYXJlbnROb2RlPShyPXRoaXNbb10pLnBhcmVudE5vZGU7Zm9yKHZhciBjPS0x
LHM9ci5sZW5ndGg7KytjPHM7KSh1PXJbY10pPyh0LnB1c2goZT1uLmNhbGwodSx1Ll9fZGF0YV9f
LGMsbykpLGUmJiJfX2RhdGFfXyJpbiB1JiYoZS5fX2RhdGFfXz11Ll9fZGF0YV9fKSk6dC5wdXNo
KG51bGwpfXJldHVybiBfKGkpfSxfYS5zZWxlY3RBbGw9ZnVuY3Rpb24obil7dmFyIHQsZSxyPVtd
O249dyhuKTtmb3IodmFyIHU9LTEsaT10aGlzLmxlbmd0aDsrK3U8aTspZm9yKHZhciBvPXRoaXNb
dV0sYT0tMSxjPW8ubGVuZ3RoOysrYTxjOykoZT1vW2FdKSYmKHIucHVzaCh0PVFvKG4uY2FsbChl
LGUuX19kYXRhX18sYSx1KSkpLHQucGFyZW50Tm9kZT1lKTtyZXR1cm4gXyhyKX07dmFyIGJhPXtz
dmc6Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIix4aHRtbDoiaHR0cDovL3d3dy53My5vcmcv
MTk5OS94aHRtbCIseGxpbms6Imh0dHA6Ly93d3cudzMub3JnLzE5OTkveGxpbmsiLHhtbDoiaHR0
cDovL3d3dy53My5vcmcvWE1MLzE5OTgvbmFtZXNwYWNlIix4bWxuczoiaHR0cDovL3d3dy53My5v
cmcvMjAwMC94bWxucy8ifTtHby5ucz17cHJlZml4OmJhLHF1YWxpZnk6ZnVuY3Rpb24obil7dmFy
IHQ9bi5pbmRleE9mKCI6IiksZT1uO3JldHVybiB0Pj0wJiYoZT1uLnN1YnN0cmluZygwLHQpLG49
bi5zdWJzdHJpbmcodCsxKSksYmEuaGFzT3duUHJvcGVydHkoZSk/e3NwYWNlOmJhW2VdLGxvY2Fs
Om59Om59fSxfYS5hdHRyPWZ1bmN0aW9uKG4sdCl7aWYoYXJndW1lbnRzLmxlbmd0aDwyKXtpZigi
c3RyaW5nIj09dHlwZW9mIG4pe3ZhciBlPXRoaXMubm9kZSgpO3JldHVybiBuPUdvLm5zLnF1YWxp
Znkobiksbi5sb2NhbD9lLmdldEF0dHJpYnV0ZU5TKG4uc3BhY2Usbi5sb2NhbCk6ZS5nZXRBdHRy
aWJ1dGUobil9Zm9yKHQgaW4gbil0aGlzLmVhY2goUyh0LG5bdF0pKTtyZXR1cm4gdGhpc31yZXR1
cm4gdGhpcy5lYWNoKFMobix0KSl9LF9hLmNsYXNzZWQ9ZnVuY3Rpb24obix0KXtpZihhcmd1bWVu
dHMubGVuZ3RoPDIpe2lmKCJzdHJpbmciPT10eXBlb2Ygbil7dmFyIGU9dGhpcy5ub2RlKCkscj0o
bj1BKG4pKS5sZW5ndGgsdT0tMTtpZih0PWUuY2xhc3NMaXN0KXtmb3IoOysrdTxyOylpZighdC5j
b250YWlucyhuW3VdKSlyZXR1cm4hMX1lbHNlIGZvcih0PWUuZ2V0QXR0cmlidXRlKCJjbGFzcyIp
OysrdTxyOylpZighRShuW3VdKS50ZXN0KHQpKXJldHVybiExO3JldHVybiEwfWZvcih0IGluIG4p
dGhpcy5lYWNoKEModCxuW3RdKSk7cmV0dXJuIHRoaXN9cmV0dXJuIHRoaXMuZWFjaChDKG4sdCkp
fSxfYS5zdHlsZT1mdW5jdGlvbihuLHQsZSl7dmFyIHI9YXJndW1lbnRzLmxlbmd0aDtpZigzPnIp
e2lmKCJzdHJpbmciIT10eXBlb2Ygbil7Mj5yJiYodD0iIik7Zm9yKGUgaW4gbil0aGlzLmVhY2go
TChlLG5bZV0sdCkpO3JldHVybiB0aGlzfWlmKDI+cilyZXR1cm4gZWEuZ2V0Q29tcHV0ZWRTdHls
ZSh0aGlzLm5vZGUoKSxudWxsKS5nZXRQcm9wZXJ0eVZhbHVlKG4pO2U9IiJ9cmV0dXJuIHRoaXMu
ZWFjaChMKG4sdCxlKSl9LF9hLnByb3BlcnR5PWZ1bmN0aW9uKG4sdCl7aWYoYXJndW1lbnRzLmxl
bmd0aDwyKXtpZigic3RyaW5nIj09dHlwZW9mIG4pcmV0dXJuIHRoaXMubm9kZSgpW25dO2Zvcih0
IGluIG4pdGhpcy5lYWNoKFQodCxuW3RdKSk7cmV0dXJuIHRoaXN9cmV0dXJuIHRoaXMuZWFjaChU
KG4sdCkpfSxfYS50ZXh0PWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoP3RoaXMu
ZWFjaCgiZnVuY3Rpb24iPT10eXBlb2Ygbj9mdW5jdGlvbigpe3ZhciB0PW4uYXBwbHkodGhpcyxh
cmd1bWVudHMpO3RoaXMudGV4dENvbnRlbnQ9bnVsbD09dD8iIjp0fTpudWxsPT1uP2Z1bmN0aW9u
KCl7dGhpcy50ZXh0Q29udGVudD0iIn06ZnVuY3Rpb24oKXt0aGlzLnRleHRDb250ZW50PW59KTp0
aGlzLm5vZGUoKS50ZXh0Q29udGVudH0sX2EuaHRtbD1mdW5jdGlvbihuKXtyZXR1cm4gYXJndW1l
bnRzLmxlbmd0aD90aGlzLmVhY2goImZ1bmN0aW9uIj09dHlwZW9mIG4/ZnVuY3Rpb24oKXt2YXIg
dD1uLmFwcGx5KHRoaXMsYXJndW1lbnRzKTt0aGlzLmlubmVySFRNTD1udWxsPT10PyIiOnR9Om51
bGw9PW4/ZnVuY3Rpb24oKXt0aGlzLmlubmVySFRNTD0iIn06ZnVuY3Rpb24oKXt0aGlzLmlubmVy
SFRNTD1ufSk6dGhpcy5ub2RlKCkuaW5uZXJIVE1MfSxfYS5hcHBlbmQ9ZnVuY3Rpb24obil7cmV0
dXJuIG49cShuKSx0aGlzLnNlbGVjdChmdW5jdGlvbigpe3JldHVybiB0aGlzLmFwcGVuZENoaWxk
KG4uYXBwbHkodGhpcyxhcmd1bWVudHMpKX0pfSxfYS5pbnNlcnQ9ZnVuY3Rpb24obix0KXtyZXR1
cm4gbj1xKG4pLHQ9Yih0KSx0aGlzLnNlbGVjdChmdW5jdGlvbigpe3JldHVybiB0aGlzLmluc2Vy
dEJlZm9yZShuLmFwcGx5KHRoaXMsYXJndW1lbnRzKSx0LmFwcGx5KHRoaXMsYXJndW1lbnRzKXx8
bnVsbCl9KX0sX2EucmVtb3ZlPWZ1bmN0aW9uKCl7cmV0dXJuIHRoaXMuZWFjaChmdW5jdGlvbigp
e3ZhciBuPXRoaXMucGFyZW50Tm9kZTtuJiZuLnJlbW92ZUNoaWxkKHRoaXMpfSl9LF9hLmRhdGE9
ZnVuY3Rpb24obix0KXtmdW5jdGlvbiBlKG4sZSl7dmFyIHIsdSxpLGE9bi5sZW5ndGgsZj1lLmxl
bmd0aCxoPU1hdGgubWluKGEsZiksZz1uZXcgQXJyYXkoZikscD1uZXcgQXJyYXkoZiksdj1uZXcg
QXJyYXkoYSk7aWYodCl7dmFyIGQsbT1uZXcgbyx5PW5ldyBvLHg9W107Zm9yKHI9LTE7KytyPGE7
KWQ9dC5jYWxsKHU9bltyXSx1Ll9fZGF0YV9fLHIpLG0uaGFzKGQpP3Zbcl09dTptLnNldChkLHUp
LHgucHVzaChkKTtmb3Iocj0tMTsrK3I8ZjspZD10LmNhbGwoZSxpPWVbcl0sciksKHU9bS5nZXQo
ZCkpPyhnW3JdPXUsdS5fX2RhdGFfXz1pKTp5LmhhcyhkKXx8KHBbcl09eihpKSkseS5zZXQoZCxp
KSxtLnJlbW92ZShkKTtmb3Iocj0tMTsrK3I8YTspbS5oYXMoeFtyXSkmJih2W3JdPW5bcl0pfWVs
c2V7Zm9yKHI9LTE7KytyPGg7KXU9bltyXSxpPWVbcl0sdT8odS5fX2RhdGFfXz1pLGdbcl09dSk6
cFtyXT16KGkpO2Zvcig7Zj5yOysrcilwW3JdPXooZVtyXSk7Zm9yKDthPnI7KytyKXZbcl09blty
XX1wLnVwZGF0ZT1nLHAucGFyZW50Tm9kZT1nLnBhcmVudE5vZGU9di5wYXJlbnROb2RlPW4ucGFy
ZW50Tm9kZSxjLnB1c2gocCkscy5wdXNoKGcpLGwucHVzaCh2KX12YXIgcix1LGk9LTEsYT10aGlz
Lmxlbmd0aDtpZighYXJndW1lbnRzLmxlbmd0aCl7Zm9yKG49bmV3IEFycmF5KGE9KHI9dGhpc1sw
XSkubGVuZ3RoKTsrK2k8YTspKHU9cltpXSkmJihuW2ldPXUuX19kYXRhX18pO3JldHVybiBufXZh
ciBjPVUoW10pLHM9XyhbXSksbD1fKFtdKTtpZigiZnVuY3Rpb24iPT10eXBlb2Ygbilmb3IoOysr
aTxhOyllKHI9dGhpc1tpXSxuLmNhbGwocixyLnBhcmVudE5vZGUuX19kYXRhX18saSkpO2Vsc2Ug
Zm9yKDsrK2k8YTspZShyPXRoaXNbaV0sbik7cmV0dXJuIHMuZW50ZXI9ZnVuY3Rpb24oKXtyZXR1
cm4gY30scy5leGl0PWZ1bmN0aW9uKCl7cmV0dXJuIGx9LHN9LF9hLmRhdHVtPWZ1bmN0aW9uKG4p
e3JldHVybiBhcmd1bWVudHMubGVuZ3RoP3RoaXMucHJvcGVydHkoIl9fZGF0YV9fIixuKTp0aGlz
LnByb3BlcnR5KCJfX2RhdGFfXyIpfSxfYS5maWx0ZXI9ZnVuY3Rpb24obil7dmFyIHQsZSxyLHU9
W107ImZ1bmN0aW9uIiE9dHlwZW9mIG4mJihuPVIobikpO2Zvcih2YXIgaT0wLG89dGhpcy5sZW5n
dGg7bz5pO2krKyl7dS5wdXNoKHQ9W10pLHQucGFyZW50Tm9kZT0oZT10aGlzW2ldKS5wYXJlbnRO
b2RlO2Zvcih2YXIgYT0wLGM9ZS5sZW5ndGg7Yz5hO2ErKykocj1lW2FdKSYmbi5jYWxsKHIsci5f
X2RhdGFfXyxhLGkpJiZ0LnB1c2gocil9cmV0dXJuIF8odSl9LF9hLm9yZGVyPWZ1bmN0aW9uKCl7
Zm9yKHZhciBuPS0xLHQ9dGhpcy5sZW5ndGg7KytuPHQ7KWZvcih2YXIgZSxyPXRoaXNbbl0sdT1y
Lmxlbmd0aC0xLGk9clt1XTstLXU+PTA7KShlPXJbdV0pJiYoaSYmaSE9PWUubmV4dFNpYmxpbmcm
JmkucGFyZW50Tm9kZS5pbnNlcnRCZWZvcmUoZSxpKSxpPWUpO3JldHVybiB0aGlzfSxfYS5zb3J0
PWZ1bmN0aW9uKG4pe249RC5hcHBseSh0aGlzLGFyZ3VtZW50cyk7Zm9yKHZhciB0PS0xLGU9dGhp
cy5sZW5ndGg7Kyt0PGU7KXRoaXNbdF0uc29ydChuKTtyZXR1cm4gdGhpcy5vcmRlcigpfSxfYS5l
YWNoPWZ1bmN0aW9uKG4pe3JldHVybiBQKHRoaXMsZnVuY3Rpb24odCxlLHIpe24uY2FsbCh0LHQu
X19kYXRhX18sZSxyKX0pfSxfYS5jYWxsPWZ1bmN0aW9uKG4pe3ZhciB0PVFvKGFyZ3VtZW50cyk7
cmV0dXJuIG4uYXBwbHkodFswXT10aGlzLHQpLHRoaXN9LF9hLmVtcHR5PWZ1bmN0aW9uKCl7cmV0
dXJuIXRoaXMubm9kZSgpfSxfYS5ub2RlPWZ1bmN0aW9uKCl7Zm9yKHZhciBuPTAsdD10aGlzLmxl
bmd0aDt0Pm47bisrKWZvcih2YXIgZT10aGlzW25dLHI9MCx1PWUubGVuZ3RoO3U+cjtyKyspe3Zh
ciBpPWVbcl07aWYoaSlyZXR1cm4gaX1yZXR1cm4gbnVsbH0sX2Euc2l6ZT1mdW5jdGlvbigpe3Zh
ciBuPTA7cmV0dXJuIHRoaXMuZWFjaChmdW5jdGlvbigpeysrbn0pLG59O3ZhciB3YT1bXTtHby5z
ZWxlY3Rpb24uZW50ZXI9VSxHby5zZWxlY3Rpb24uZW50ZXIucHJvdG90eXBlPXdhLHdhLmFwcGVu
ZD1fYS5hcHBlbmQsd2EuZW1wdHk9X2EuZW1wdHksd2Eubm9kZT1fYS5ub2RlLHdhLmNhbGw9X2Eu
Y2FsbCx3YS5zaXplPV9hLnNpemUsd2Euc2VsZWN0PWZ1bmN0aW9uKG4pe2Zvcih2YXIgdCxlLHIs
dSxpLG89W10sYT0tMSxjPXRoaXMubGVuZ3RoOysrYTxjOyl7cj0odT10aGlzW2FdKS51cGRhdGUs
by5wdXNoKHQ9W10pLHQucGFyZW50Tm9kZT11LnBhcmVudE5vZGU7Zm9yKHZhciBzPS0xLGw9dS5s
ZW5ndGg7KytzPGw7KShpPXVbc10pPyh0LnB1c2gocltzXT1lPW4uY2FsbCh1LnBhcmVudE5vZGUs
aS5fX2RhdGFfXyxzLGEpKSxlLl9fZGF0YV9fPWkuX19kYXRhX18pOnQucHVzaChudWxsKX1yZXR1
cm4gXyhvKX0sd2EuaW5zZXJ0PWZ1bmN0aW9uKG4sdCl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg8
MiYmKHQ9aih0aGlzKSksX2EuaW5zZXJ0LmNhbGwodGhpcyxuLHQpfSxfYS50cmFuc2l0aW9uPWZ1
bmN0aW9uKCl7Zm9yKHZhciBuLHQsZT1Mc3x8KytEcyxyPVtdLHU9VHN8fHt0aW1lOkRhdGUubm93
KCksZWFzZTp3dSxkZWxheTowLGR1cmF0aW9uOjI1MH0saT0tMSxvPXRoaXMubGVuZ3RoOysraTxv
Oyl7ci5wdXNoKG49W10pO2Zvcih2YXIgYT10aGlzW2ldLGM9LTEscz1hLmxlbmd0aDsrK2M8czsp
KHQ9YVtjXSkmJllvKHQsYyxlLHUpLG4ucHVzaCh0KX1yZXR1cm4gRm8ocixlKX0sX2EuaW50ZXJy
dXB0PWZ1bmN0aW9uKCl7cmV0dXJuIHRoaXMuZWFjaChIKX0sR28uc2VsZWN0PWZ1bmN0aW9uKG4p
e3ZhciB0PVsic3RyaW5nIj09dHlwZW9mIG4/bWEobixuYSk6bl07cmV0dXJuIHQucGFyZW50Tm9k
ZT10YSxfKFt0XSl9LEdvLnNlbGVjdEFsbD1mdW5jdGlvbihuKXt2YXIgdD1Rbygic3RyaW5nIj09
dHlwZW9mIG4/eWEobixuYSk6bik7cmV0dXJuIHQucGFyZW50Tm9kZT10YSxfKFt0XSl9O3ZhciBT
YT1Hby5zZWxlY3QodGEpO19hLm9uPWZ1bmN0aW9uKG4sdCxlKXt2YXIgcj1hcmd1bWVudHMubGVu
Z3RoO2lmKDM+cil7aWYoInN0cmluZyIhPXR5cGVvZiBuKXsyPnImJih0PSExKTtmb3IoZSBpbiBu
KXRoaXMuZWFjaChGKGUsbltlXSx0KSk7cmV0dXJuIHRoaXN9aWYoMj5yKXJldHVybihyPXRoaXMu
bm9kZSgpWyJfX29uIituXSkmJnIuXztlPSExfXJldHVybiB0aGlzLmVhY2goRihuLHQsZSkpfTt2
YXIga2E9R28ubWFwKHttb3VzZWVudGVyOiJtb3VzZW92ZXIiLG1vdXNlbGVhdmU6Im1vdXNlb3V0
In0pO2thLmZvckVhY2goZnVuY3Rpb24obil7Im9uIituIGluIG5hJiZrYS5yZW1vdmUobil9KTt2
YXIgRWE9Im9uc2VsZWN0c3RhcnQiaW4gbmE/bnVsbDpwKHRhLnN0eWxlLCJ1c2VyU2VsZWN0Iiks
QWE9MDtHby5tb3VzZT1mdW5jdGlvbihuKXtyZXR1cm4gWihuLHgoKSl9LEdvLnRvdWNoZXM9ZnVu
Y3Rpb24obix0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aDwyJiYodD14KCkudG91Y2hlcyksdD9R
byh0KS5tYXAoZnVuY3Rpb24odCl7dmFyIGU9WihuLHQpO3JldHVybiBlLmlkZW50aWZpZXI9dC5p
ZGVudGlmaWVyLGV9KTpbXX0sR28uYmVoYXZpb3IuZHJhZz1mdW5jdGlvbigpe2Z1bmN0aW9uIG4o
KXt0aGlzLm9uKCJtb3VzZWRvd24uZHJhZyIsdSkub24oInRvdWNoc3RhcnQuZHJhZyIsaSl9ZnVu
Y3Rpb24gdChuLHQsdSxpLG8pe3JldHVybiBmdW5jdGlvbigpe2Z1bmN0aW9uIGEoKXt2YXIgbixl
LHI9dChoLHYpO3ImJihuPXJbMF0teFswXSxlPXJbMV0teFsxXSxwfD1ufGUseD1yLGcoe3R5cGU6
ImRyYWciLHg6clswXStzWzBdLHk6clsxXStzWzFdLGR4Om4sZHk6ZX0pKX1mdW5jdGlvbiBjKCl7
dChoLHYpJiYobS5vbihpK2QsbnVsbCkub24obytkLG51bGwpLHkocCYmR28uZXZlbnQudGFyZ2V0
PT09ZiksZyh7dHlwZToiZHJhZ2VuZCJ9KSl9dmFyIHMsbD10aGlzLGY9R28uZXZlbnQudGFyZ2V0
LGg9bC5wYXJlbnROb2RlLGc9ZS5vZihsLGFyZ3VtZW50cykscD0wLHY9bigpLGQ9Ii5kcmFnIiso
bnVsbD09dj8iIjoiLSIrdiksbT1Hby5zZWxlY3QodSgpKS5vbihpK2QsYSkub24obytkLGMpLHk9
WSgpLHg9dChoLHYpO3I/KHM9ci5hcHBseShsLGFyZ3VtZW50cykscz1bcy54LXhbMF0scy55LXhb
MV1dKTpzPVswLDBdLGcoe3R5cGU6ImRyYWdzdGFydCJ9KX19dmFyIGU9TShuLCJkcmFnIiwiZHJh
Z3N0YXJ0IiwiZHJhZ2VuZCIpLHI9bnVsbCx1PXQodixHby5tb3VzZSxYLCJtb3VzZW1vdmUiLCJt
b3VzZXVwIiksaT10KFYsR28udG91Y2gsJCwidG91Y2htb3ZlIiwidG91Y2hlbmQiKTtyZXR1cm4g
bi5vcmlnaW49ZnVuY3Rpb24odCl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KHI9dCxuKTpyfSxH
by5yZWJpbmQobixlLCJvbiIpfTt2YXIgQ2E9TWF0aC5QSSxOYT0yKkNhLExhPUNhLzIsVGE9MWUt
NixxYT1UYSpUYSx6YT1DYS8xODAsUmE9MTgwL0NhLERhPU1hdGguU1FSVDIsUGE9MixVYT00O0dv
LmludGVycG9sYXRlWm9vbT1mdW5jdGlvbihuLHQpe2Z1bmN0aW9uIGUobil7dmFyIHQ9bip5O2lm
KG0pe3ZhciBlPVEodiksbz1pLyhQYSpoKSooZSpudChEYSp0K3YpLUsodikpO3JldHVybltyK28q
cyx1K28qbCxpKmUvUShEYSp0K3YpXX1yZXR1cm5bcituKnMsdStuKmwsaSpNYXRoLmV4cChEYSp0
KV19dmFyIHI9blswXSx1PW5bMV0saT1uWzJdLG89dFswXSxhPXRbMV0sYz10WzJdLHM9by1yLGw9
YS11LGY9cypzK2wqbCxoPU1hdGguc3FydChmKSxnPShjKmMtaSppK1VhKmYpLygyKmkqUGEqaCks
cD0oYypjLWkqaS1VYSpmKS8oMipjKlBhKmgpLHY9TWF0aC5sb2coTWF0aC5zcXJ0KGcqZysxKS1n
KSxkPU1hdGgubG9nKE1hdGguc3FydChwKnArMSktcCksbT1kLXYseT0obXx8TWF0aC5sb2coYy9p
KSkvRGE7cmV0dXJuIGUuZHVyYXRpb249MWUzKnksZX0sR28uYmVoYXZpb3Iuem9vbT1mdW5jdGlv
bigpe2Z1bmN0aW9uIG4obil7bi5vbihBLHMpLm9uKEZhKyIuem9vbSIsZikub24oQyxoKS5vbigi
ZGJsY2xpY2suem9vbSIsZykub24oTCxsKX1mdW5jdGlvbiB0KG4pe3JldHVyblsoblswXS1TLngp
L1MuaywoblsxXS1TLnkpL1Mua119ZnVuY3Rpb24gZShuKXtyZXR1cm5bblswXSpTLmsrUy54LG5b
MV0qUy5rK1MueV19ZnVuY3Rpb24gcihuKXtTLms9TWF0aC5tYXgoRVswXSxNYXRoLm1pbihFWzFd
LG4pKX1mdW5jdGlvbiB1KG4sdCl7dD1lKHQpLFMueCs9blswXS10WzBdLFMueSs9blsxXS10WzFd
fWZ1bmN0aW9uIGkoKXtfJiZfLmRvbWFpbih4LnJhbmdlKCkubWFwKGZ1bmN0aW9uKG4pe3JldHVy
bihuLVMueCkvUy5rfSkubWFwKHguaW52ZXJ0KSksdyYmdy5kb21haW4oYi5yYW5nZSgpLm1hcChm
dW5jdGlvbihuKXtyZXR1cm4obi1TLnkpL1Mua30pLm1hcChiLmludmVydCkpfWZ1bmN0aW9uIG8o
bil7bih7dHlwZToiem9vbXN0YXJ0In0pfWZ1bmN0aW9uIGEobil7aSgpLG4oe3R5cGU6Inpvb20i
LHNjYWxlOlMuayx0cmFuc2xhdGU6W1MueCxTLnldfSl9ZnVuY3Rpb24gYyhuKXtuKHt0eXBlOiJ6
b29tZW5kIn0pfWZ1bmN0aW9uIHMoKXtmdW5jdGlvbiBuKCl7bD0xLHUoR28ubW91c2UociksZyks
YShzKX1mdW5jdGlvbiBlKCl7Zi5vbihDLGVhPT09cj9oOm51bGwpLm9uKE4sbnVsbCkscChsJiZH
by5ldmVudC50YXJnZXQ9PT1pKSxjKHMpfXZhciByPXRoaXMsaT1Hby5ldmVudC50YXJnZXQscz1U
Lm9mKHIsYXJndW1lbnRzKSxsPTAsZj1Hby5zZWxlY3QoZWEpLm9uKEMsbikub24oTixlKSxnPXQo
R28ubW91c2UocikpLHA9WSgpO0guY2FsbChyKSxvKHMpfWZ1bmN0aW9uIGwoKXtmdW5jdGlvbiBu
KCl7dmFyIG49R28udG91Y2hlcyhnKTtyZXR1cm4gaD1TLmssbi5mb3JFYWNoKGZ1bmN0aW9uKG4p
e24uaWRlbnRpZmllciBpbiB2JiYodltuLmlkZW50aWZpZXJdPXQobikpfSksbn1mdW5jdGlvbiBl
KCl7Zm9yKHZhciB0PUdvLmV2ZW50LmNoYW5nZWRUb3VjaGVzLGU9MCxpPXQubGVuZ3RoO2k+ZTsr
K2Updlt0W2VdLmlkZW50aWZpZXJdPW51bGw7dmFyIG89bigpLGM9RGF0ZS5ub3coKTtpZigxPT09
by5sZW5ndGgpe2lmKDUwMD5jLW0pe3ZhciBzPW9bMF0sbD12W3MuaWRlbnRpZmllcl07cigyKlMu
ayksdShzLGwpLHkoKSxhKHApfW09Y31lbHNlIGlmKG8ubGVuZ3RoPjEpe3ZhciBzPW9bMF0sZj1v
WzFdLGg9c1swXS1mWzBdLGc9c1sxXS1mWzFdO2Q9aCpoK2cqZ319ZnVuY3Rpb24gaSgpe2Zvcih2
YXIgbix0LGUsaSxvPUdvLnRvdWNoZXMoZyksYz0wLHM9by5sZW5ndGg7cz5jOysrYyxpPW51bGwp
aWYoZT1vW2NdLGk9dltlLmlkZW50aWZpZXJdKXtpZih0KWJyZWFrO249ZSx0PWl9aWYoaSl7dmFy
IGw9KGw9ZVswXS1uWzBdKSpsKyhsPWVbMV0tblsxXSkqbCxmPWQmJk1hdGguc3FydChsL2QpO249
WyhuWzBdK2VbMF0pLzIsKG5bMV0rZVsxXSkvMl0sdD1bKHRbMF0raVswXSkvMiwodFsxXStpWzFd
KS8yXSxyKGYqaCl9bT1udWxsLHUobix0KSxhKHApfWZ1bmN0aW9uIGYoKXtpZihHby5ldmVudC50
b3VjaGVzLmxlbmd0aCl7Zm9yKHZhciB0PUdvLmV2ZW50LmNoYW5nZWRUb3VjaGVzLGU9MCxyPXQu
bGVuZ3RoO3I+ZTsrK2UpZGVsZXRlIHZbdFtlXS5pZGVudGlmaWVyXTtmb3IodmFyIHUgaW4gdily
ZXR1cm4gdm9pZCBuKCl9Yi5vbih4LG51bGwpLHcub24oQSxzKS5vbihMLGwpLGsoKSxjKHApfXZh
ciBoLGc9dGhpcyxwPVQub2YoZyxhcmd1bWVudHMpLHY9e30sZD0wLHg9Ii56b29tLSIrR28uZXZl
bnQuY2hhbmdlZFRvdWNoZXNbMF0uaWRlbnRpZmllcixNPSJ0b3VjaG1vdmUiK3gsXz0idG91Y2hl
bmQiK3gsYj1Hby5zZWxlY3QoR28uZXZlbnQudGFyZ2V0KS5vbihNLGkpLm9uKF8sZiksdz1Hby5z
ZWxlY3QoZykub24oQSxudWxsKS5vbihMLGUpLGs9WSgpO0guY2FsbChnKSxlKCksbyhwKX1mdW5j
dGlvbiBmKCl7dmFyIG49VC5vZih0aGlzLGFyZ3VtZW50cyk7ZD9jbGVhclRpbWVvdXQoZCk6KEgu
Y2FsbCh0aGlzKSxvKG4pKSxkPXNldFRpbWVvdXQoZnVuY3Rpb24oKXtkPW51bGwsYyhuKX0sNTAp
LHkoKTt2YXIgZT12fHxHby5tb3VzZSh0aGlzKTtwfHwocD10KGUpKSxyKE1hdGgucG93KDIsLjAw
MipqYSgpKSpTLmspLHUoZSxwKSxhKG4pfWZ1bmN0aW9uIGgoKXtwPW51bGx9ZnVuY3Rpb24gZygp
e3ZhciBuPVQub2YodGhpcyxhcmd1bWVudHMpLGU9R28ubW91c2UodGhpcyksaT10KGUpLHM9TWF0
aC5sb2coUy5rKS9NYXRoLkxOMjtvKG4pLHIoTWF0aC5wb3coMixHby5ldmVudC5zaGlmdEtleT9N
YXRoLmNlaWwocyktMTpNYXRoLmZsb29yKHMpKzEpKSx1KGUsaSksYShuKSxjKG4pfXZhciBwLHYs
ZCxtLHgsXyxiLHcsUz17eDowLHk6MCxrOjF9LGs9Wzk2MCw1MDBdLEU9SGEsQT0ibW91c2Vkb3du
Lnpvb20iLEM9Im1vdXNlbW92ZS56b29tIixOPSJtb3VzZXVwLnpvb20iLEw9InRvdWNoc3RhcnQu
em9vbSIsVD1NKG4sInpvb21zdGFydCIsInpvb20iLCJ6b29tZW5kIik7cmV0dXJuIG4uZXZlbnQ9
ZnVuY3Rpb24obil7bi5lYWNoKGZ1bmN0aW9uKCl7dmFyIG49VC5vZih0aGlzLGFyZ3VtZW50cyks
dD1TO0xzP0dvLnNlbGVjdCh0aGlzKS50cmFuc2l0aW9uKCkuZWFjaCgic3RhcnQuem9vbSIsZnVu
Y3Rpb24oKXtTPXRoaXMuX19jaGFydF9ffHx7eDowLHk6MCxrOjF9LG8obil9KS50d2Vlbigiem9v
bTp6b29tIixmdW5jdGlvbigpe3ZhciBlPWtbMF0scj1rWzFdLHU9ZS8yLGk9ci8yLG89R28uaW50
ZXJwb2xhdGVab29tKFsodS1TLngpL1MuaywoaS1TLnkpL1MuayxlL1Mua10sWyh1LXQueCkvdC5r
LChpLXQueSkvdC5rLGUvdC5rXSk7cmV0dXJuIGZ1bmN0aW9uKHQpe3ZhciByPW8odCksYz1lL3Jb
Ml07dGhpcy5fX2NoYXJ0X189Uz17eDp1LXJbMF0qYyx5OmktclsxXSpjLGs6Y30sYShuKX19KS5l
YWNoKCJlbmQuem9vbSIsZnVuY3Rpb24oKXtjKG4pfSk6KHRoaXMuX19jaGFydF9fPVMsbyhuKSxh
KG4pLGMobikpfSl9LG4udHJhbnNsYXRlPWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMubGVu
Z3RoPyhTPXt4Oit0WzBdLHk6K3RbMV0sazpTLmt9LGkoKSxuKTpbUy54LFMueV19LG4uc2NhbGU9
ZnVuY3Rpb24odCl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KFM9e3g6Uy54LHk6Uy55LGs6K3R9
LGkoKSxuKTpTLmt9LG4uc2NhbGVFeHRlbnQ9ZnVuY3Rpb24odCl7cmV0dXJuIGFyZ3VtZW50cy5s
ZW5ndGg/KEU9bnVsbD09dD9IYTpbK3RbMF0sK3RbMV1dLG4pOkV9LG4uY2VudGVyPWZ1bmN0aW9u
KHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyh2PXQmJlsrdFswXSwrdFsxXV0sbik6dn0sbi5z
aXplPWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhrPXQmJlsrdFswXSwrdFsx
XV0sbik6a30sbi54PWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhfPXQseD10
LmNvcHkoKSxTPXt4OjAseTowLGs6MX0sbik6X30sbi55PWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1
bWVudHMubGVuZ3RoPyh3PXQsYj10LmNvcHkoKSxTPXt4OjAseTowLGs6MX0sbik6d30sR28ucmVi
aW5kKG4sVCwib24iKX07dmFyIGphLEhhPVswLDEvMF0sRmE9Im9ud2hlZWwiaW4gbmE/KGphPWZ1
bmN0aW9uKCl7cmV0dXJuLUdvLmV2ZW50LmRlbHRhWSooR28uZXZlbnQuZGVsdGFNb2RlPzEyMDox
KX0sIndoZWVsIik6Im9ubW91c2V3aGVlbCJpbiBuYT8oamE9ZnVuY3Rpb24oKXtyZXR1cm4gR28u
ZXZlbnQud2hlZWxEZWx0YX0sIm1vdXNld2hlZWwiKTooamE9ZnVuY3Rpb24oKXtyZXR1cm4tR28u
ZXZlbnQuZGV0YWlsfSwiTW96TW91c2VQaXhlbFNjcm9sbCIpO2V0LnByb3RvdHlwZS50b1N0cmlu
Zz1mdW5jdGlvbigpe3JldHVybiB0aGlzLnJnYigpKyIifSxHby5oc2w9ZnVuY3Rpb24obix0LGUp
e3JldHVybiAxPT09YXJndW1lbnRzLmxlbmd0aD9uIGluc3RhbmNlb2YgdXQ/cnQobi5oLG4ucyxu
LmwpOl90KCIiK24sYnQscnQpOnJ0KCtuLCt0LCtlKX07dmFyIE9hPXV0LnByb3RvdHlwZT1uZXcg
ZXQ7T2EuYnJpZ2h0ZXI9ZnVuY3Rpb24obil7cmV0dXJuIG49TWF0aC5wb3coLjcsYXJndW1lbnRz
Lmxlbmd0aD9uOjEpLHJ0KHRoaXMuaCx0aGlzLnMsdGhpcy5sL24pfSxPYS5kYXJrZXI9ZnVuY3Rp
b24obil7cmV0dXJuIG49TWF0aC5wb3coLjcsYXJndW1lbnRzLmxlbmd0aD9uOjEpLHJ0KHRoaXMu
aCx0aGlzLnMsbip0aGlzLmwpfSxPYS5yZ2I9ZnVuY3Rpb24oKXtyZXR1cm4gaXQodGhpcy5oLHRo
aXMucyx0aGlzLmwpfSxHby5oY2w9ZnVuY3Rpb24obix0LGUpe3JldHVybiAxPT09YXJndW1lbnRz
Lmxlbmd0aD9uIGluc3RhbmNlb2YgYXQ/b3Qobi5oLG4uYyxuLmwpOm4gaW5zdGFuY2VvZiBsdD9o
dChuLmwsbi5hLG4uYik6aHQoKG49d3QoKG49R28ucmdiKG4pKS5yLG4uZyxuLmIpKS5sLG4uYSxu
LmIpOm90KCtuLCt0LCtlKX07dmFyIElhPWF0LnByb3RvdHlwZT1uZXcgZXQ7SWEuYnJpZ2h0ZXI9
ZnVuY3Rpb24obil7cmV0dXJuIG90KHRoaXMuaCx0aGlzLmMsTWF0aC5taW4oMTAwLHRoaXMubCtZ
YSooYXJndW1lbnRzLmxlbmd0aD9uOjEpKSl9LElhLmRhcmtlcj1mdW5jdGlvbihuKXtyZXR1cm4g
b3QodGhpcy5oLHRoaXMuYyxNYXRoLm1heCgwLHRoaXMubC1ZYSooYXJndW1lbnRzLmxlbmd0aD9u
OjEpKSl9LElhLnJnYj1mdW5jdGlvbigpe3JldHVybiBjdCh0aGlzLmgsdGhpcy5jLHRoaXMubCku
cmdiKCl9LEdvLmxhYj1mdW5jdGlvbihuLHQsZSl7cmV0dXJuIDE9PT1hcmd1bWVudHMubGVuZ3Ro
P24gaW5zdGFuY2VvZiBsdD9zdChuLmwsbi5hLG4uYik6biBpbnN0YW5jZW9mIGF0P2N0KG4ubCxu
LmMsbi5oKTp3dCgobj1Hby5yZ2IobikpLnIsbi5nLG4uYik6c3QoK24sK3QsK2UpfTt2YXIgWWE9
MTgsWmE9Ljk1MDQ3LFZhPTEsJGE9MS4wODg4MyxYYT1sdC5wcm90b3R5cGU9bmV3IGV0O1hhLmJy
aWdodGVyPWZ1bmN0aW9uKG4pe3JldHVybiBzdChNYXRoLm1pbigxMDAsdGhpcy5sK1lhKihhcmd1
bWVudHMubGVuZ3RoP246MSkpLHRoaXMuYSx0aGlzLmIpfSxYYS5kYXJrZXI9ZnVuY3Rpb24obil7
cmV0dXJuIHN0KE1hdGgubWF4KDAsdGhpcy5sLVlhKihhcmd1bWVudHMubGVuZ3RoP246MSkpLHRo
aXMuYSx0aGlzLmIpfSxYYS5yZ2I9ZnVuY3Rpb24oKXtyZXR1cm4gZnQodGhpcy5sLHRoaXMuYSx0
aGlzLmIpfSxHby5yZ2I9ZnVuY3Rpb24obix0LGUpe3JldHVybiAxPT09YXJndW1lbnRzLmxlbmd0
aD9uIGluc3RhbmNlb2YgeHQ/eXQobi5yLG4uZyxuLmIpOl90KCIiK24seXQsaXQpOnl0KH5+bix+
fnQsfn5lKX07dmFyIEJhPXh0LnByb3RvdHlwZT1uZXcgZXQ7QmEuYnJpZ2h0ZXI9ZnVuY3Rpb24o
bil7bj1NYXRoLnBvdyguNyxhcmd1bWVudHMubGVuZ3RoP246MSk7dmFyIHQ9dGhpcy5yLGU9dGhp
cy5nLHI9dGhpcy5iLHU9MzA7cmV0dXJuIHR8fGV8fHI/KHQmJnU+dCYmKHQ9dSksZSYmdT5lJiYo
ZT11KSxyJiZ1PnImJihyPXUpLHl0KE1hdGgubWluKDI1NSx+fih0L24pKSxNYXRoLm1pbigyNTUs
fn4oZS9uKSksTWF0aC5taW4oMjU1LH5+KHIvbikpKSk6eXQodSx1LHUpfSxCYS5kYXJrZXI9ZnVu
Y3Rpb24obil7cmV0dXJuIG49TWF0aC5wb3coLjcsYXJndW1lbnRzLmxlbmd0aD9uOjEpLHl0KH5+
KG4qdGhpcy5yKSx+fihuKnRoaXMuZyksfn4obip0aGlzLmIpKX0sQmEuaHNsPWZ1bmN0aW9uKCl7
cmV0dXJuIGJ0KHRoaXMucix0aGlzLmcsdGhpcy5iKX0sQmEudG9TdHJpbmc9ZnVuY3Rpb24oKXty
ZXR1cm4iIyIrTXQodGhpcy5yKStNdCh0aGlzLmcpK010KHRoaXMuYil9O3ZhciBKYT1Hby5tYXAo
e2FsaWNlYmx1ZToxNTc5MjM4MyxhbnRpcXVld2hpdGU6MTY0NDQzNzUsYXF1YTo2NTUzNSxhcXVh
bWFyaW5lOjgzODg1NjQsYXp1cmU6MTU3OTQxNzUsYmVpZ2U6MTYxMTkyNjAsYmlzcXVlOjE2Nzcw
MjQ0LGJsYWNrOjAsYmxhbmNoZWRhbG1vbmQ6MTY3NzIwNDUsYmx1ZToyNTUsYmx1ZXZpb2xldDo5
MDU1MjAyLGJyb3duOjEwODI0MjM0LGJ1cmx5d29vZDoxNDU5NjIzMSxjYWRldGJsdWU6NjI2NjUy
OCxjaGFydHJldXNlOjgzODgzNTIsY2hvY29sYXRlOjEzNzg5NDcwLGNvcmFsOjE2NzQ0MjcyLGNv
cm5mbG93ZXJibHVlOjY1OTE5ODEsY29ybnNpbGs6MTY3NzUzODgsY3JpbXNvbjoxNDQyMzEwMCxj
eWFuOjY1NTM1LGRhcmtibHVlOjEzOSxkYXJrY3lhbjozNTcyMyxkYXJrZ29sZGVucm9kOjEyMDky
OTM5LGRhcmtncmF5OjExMTE5MDE3LGRhcmtncmVlbjoyNTYwMCxkYXJrZ3JleToxMTExOTAxNyxk
YXJra2hha2k6MTI0MzMyNTksZGFya21hZ2VudGE6OTEwOTY0MyxkYXJrb2xpdmVncmVlbjo1NTk3
OTk5LGRhcmtvcmFuZ2U6MTY3NDc1MjAsZGFya29yY2hpZDoxMDA0MDAxMixkYXJrcmVkOjkxMDk1
MDQsZGFya3NhbG1vbjoxNTMwODQxMCxkYXJrc2VhZ3JlZW46OTQxOTkxOSxkYXJrc2xhdGVibHVl
OjQ3MzQzNDcsZGFya3NsYXRlZ3JheTozMTAwNDk1LGRhcmtzbGF0ZWdyZXk6MzEwMDQ5NSxkYXJr
dHVycXVvaXNlOjUyOTQ1LGRhcmt2aW9sZXQ6OTY5OTUzOSxkZWVwcGluazoxNjcxNjk0NyxkZWVw
c2t5Ymx1ZTo0OTE1MSxkaW1ncmF5OjY5MDgyNjUsZGltZ3JleTo2OTA4MjY1LGRvZGdlcmJsdWU6
MjAwMzE5OSxmaXJlYnJpY2s6MTE2NzQxNDYsZmxvcmFsd2hpdGU6MTY3NzU5MjAsZm9yZXN0Z3Jl
ZW46MjI2Mzg0MixmdWNoc2lhOjE2NzExOTM1LGdhaW5zYm9ybzoxNDQ3NDQ2MCxnaG9zdHdoaXRl
OjE2MzE2NjcxLGdvbGQ6MTY3NjY3MjAsZ29sZGVucm9kOjE0MzI5MTIwLGdyYXk6ODQyMTUwNCxn
cmVlbjozMjc2OCxncmVlbnllbGxvdzoxMTQwMzA1NSxncmV5Ojg0MjE1MDQsaG9uZXlkZXc6MTU3
OTQxNjAsaG90cGluazoxNjczODc0MCxpbmRpYW5yZWQ6MTM0NTg1MjQsaW5kaWdvOjQ5MTUzMzAs
aXZvcnk6MTY3NzcyMDAsa2hha2k6MTU3ODc2NjAsbGF2ZW5kZXI6MTUxMzI0MTAsbGF2ZW5kZXJi
bHVzaDoxNjc3MzM2NSxsYXduZ3JlZW46ODE5MDk3NixsZW1vbmNoaWZmb246MTY3NzU4ODUsbGln
aHRibHVlOjExMzkzMjU0LGxpZ2h0Y29yYWw6MTU3NjE1MzYsbGlnaHRjeWFuOjE0NzQ1NTk5LGxp
Z2h0Z29sZGVucm9keWVsbG93OjE2NDQ4MjEwLGxpZ2h0Z3JheToxMzg4MjMyMyxsaWdodGdyZWVu
Ojk0OTgyNTYsbGlnaHRncmV5OjEzODgyMzIzLGxpZ2h0cGluazoxNjc1ODQ2NSxsaWdodHNhbG1v
bjoxNjc1Mjc2MixsaWdodHNlYWdyZWVuOjIxNDI4OTAsbGlnaHRza3libHVlOjg5MDAzNDYsbGln
aHRzbGF0ZWdyYXk6NzgzMzc1MyxsaWdodHNsYXRlZ3JleTo3ODMzNzUzLGxpZ2h0c3RlZWxibHVl
OjExNTg0NzM0LGxpZ2h0eWVsbG93OjE2Nzc3MTg0LGxpbWU6NjUyODAsbGltZWdyZWVuOjMzMjkz
MzAsbGluZW46MTY0NDU2NzAsbWFnZW50YToxNjcxMTkzNSxtYXJvb246ODM4ODYwOCxtZWRpdW1h
cXVhbWFyaW5lOjY3MzczMjIsbWVkaXVtYmx1ZToyMDUsbWVkaXVtb3JjaGlkOjEyMjExNjY3LG1l
ZGl1bXB1cnBsZTo5NjYyNjgzLG1lZGl1bXNlYWdyZWVuOjM5NzgwOTcsbWVkaXVtc2xhdGVibHVl
OjgwODc3OTAsbWVkaXVtc3ByaW5nZ3JlZW46NjQxNTQsbWVkaXVtdHVycXVvaXNlOjQ3NzIzMDAs
bWVkaXVtdmlvbGV0cmVkOjEzMDQ3MTczLG1pZG5pZ2h0Ymx1ZToxNjQ0OTEyLG1pbnRjcmVhbTox
NjEyMTg1MCxtaXN0eXJvc2U6MTY3NzAyNzMsbW9jY2FzaW46MTY3NzAyMjksbmF2YWpvd2hpdGU6
MTY3Njg2ODUsbmF2eToxMjgsb2xkbGFjZToxNjY0MzU1OCxvbGl2ZTo4NDIxMzc2LG9saXZlZHJh
Yjo3MDQ4NzM5LG9yYW5nZToxNjc1MzkyMCxvcmFuZ2VyZWQ6MTY3MjkzNDQsb3JjaGlkOjE0MzE1
NzM0LHBhbGVnb2xkZW5yb2Q6MTU2NTcxMzAscGFsZWdyZWVuOjEwMDI1ODgwLHBhbGV0dXJxdW9p
c2U6MTE1Mjk5NjYscGFsZXZpb2xldHJlZDoxNDM4MTIwMyxwYXBheWF3aGlwOjE2NzczMDc3LHBl
YWNocHVmZjoxNjc2NzY3MyxwZXJ1OjEzNDY4OTkxLHBpbms6MTY3NjEwMzUscGx1bToxNDUyNDYz
Nyxwb3dkZXJibHVlOjExNTkxOTEwLHB1cnBsZTo4Mzg4NzM2LHJlZDoxNjcxMTY4MCxyb3N5YnJv
d246MTIzNTc1MTkscm95YWxibHVlOjQyODY5NDUsc2FkZGxlYnJvd246OTEyNzE4NyxzYWxtb246
MTY0MTY4ODIsc2FuZHlicm93bjoxNjAzMjg2NCxzZWFncmVlbjozMDUwMzI3LHNlYXNoZWxsOjE2
Nzc0NjM4LHNpZW5uYToxMDUwNjc5NyxzaWx2ZXI6MTI2MzIyNTYsc2t5Ymx1ZTo4OTAwMzMxLHNs
YXRlYmx1ZTo2OTcwMDYxLHNsYXRlZ3JheTo3MzcyOTQ0LHNsYXRlZ3JleTo3MzcyOTQ0LHNub3c6
MTY3NzU5MzAsc3ByaW5nZ3JlZW46NjU0MDcsc3RlZWxibHVlOjQ2MjA5ODAsdGFuOjEzODA4Nzgw
LHRlYWw6MzI4OTYsdGhpc3RsZToxNDIwNDg4OCx0b21hdG86MTY3MzcwOTUsdHVycXVvaXNlOjQy
NTE4NTYsdmlvbGV0OjE1NjMxMDg2LHdoZWF0OjE2MTEzMzMxLHdoaXRlOjE2Nzc3MjE1LHdoaXRl
c21va2U6MTYxMTkyODUseWVsbG93OjE2Nzc2OTYwLHllbGxvd2dyZWVuOjEwMTQ1MDc0fSk7SmEu
Zm9yRWFjaChmdW5jdGlvbihuLHQpe0phLnNldChuLGR0KHQpKX0pLEdvLmZ1bmN0b3I9RXQsR28u
eGhyPUN0KEF0KSxHby5kc3Y9ZnVuY3Rpb24obix0KXtmdW5jdGlvbiBlKG4sZSxpKXthcmd1bWVu
dHMubGVuZ3RoPDMmJihpPWUsZT1udWxsKTt2YXIgbz1OdChuLHQsbnVsbD09ZT9yOnUoZSksaSk7
cmV0dXJuIG8ucm93PWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoP28ucmVzcG9u
c2UobnVsbD09KGU9bik/cjp1KG4pKTplfSxvfWZ1bmN0aW9uIHIobil7cmV0dXJuIGUucGFyc2Uo
bi5yZXNwb25zZVRleHQpfWZ1bmN0aW9uIHUobil7cmV0dXJuIGZ1bmN0aW9uKHQpe3JldHVybiBl
LnBhcnNlKHQucmVzcG9uc2VUZXh0LG4pfX1mdW5jdGlvbiBpKHQpe3JldHVybiB0Lm1hcChvKS5q
b2luKG4pfWZ1bmN0aW9uIG8obil7cmV0dXJuIGEudGVzdChuKT8nIicrbi5yZXBsYWNlKC9cIi9n
LCciIicpKyciJzpufXZhciBhPW5ldyBSZWdFeHAoJ1siJytuKyJcbl0iKSxjPW4uY2hhckNvZGVB
dCgwKTtyZXR1cm4gZS5wYXJzZT1mdW5jdGlvbihuLHQpe3ZhciByO3JldHVybiBlLnBhcnNlUm93
cyhuLGZ1bmN0aW9uKG4sZSl7aWYocilyZXR1cm4gcihuLGUtMSk7dmFyIHU9bmV3IEZ1bmN0aW9u
KCJkIiwicmV0dXJuIHsiK24ubWFwKGZ1bmN0aW9uKG4sdCl7cmV0dXJuIEpTT04uc3RyaW5naWZ5
KG4pKyI6IGRbIit0KyJdIn0pLmpvaW4oIiwiKSsifSIpO3I9dD9mdW5jdGlvbihuLGUpe3JldHVy
biB0KHUobiksZSl9OnV9KX0sZS5wYXJzZVJvd3M9ZnVuY3Rpb24obix0KXtmdW5jdGlvbiBlKCl7
aWYobD49cylyZXR1cm4gbztpZih1KXJldHVybiB1PSExLGk7dmFyIHQ9bDtpZigzND09PW4uY2hh
ckNvZGVBdCh0KSl7Zm9yKHZhciBlPXQ7ZSsrPHM7KWlmKDM0PT09bi5jaGFyQ29kZUF0KGUpKXtp
ZigzNCE9PW4uY2hhckNvZGVBdChlKzEpKWJyZWFrOysrZX1sPWUrMjt2YXIgcj1uLmNoYXJDb2Rl
QXQoZSsxKTtyZXR1cm4gMTM9PT1yPyh1PSEwLDEwPT09bi5jaGFyQ29kZUF0KGUrMikmJisrbCk6
MTA9PT1yJiYodT0hMCksbi5zdWJzdHJpbmcodCsxLGUpLnJlcGxhY2UoLyIiL2csJyInKX1mb3Io
O3M+bDspe3ZhciByPW4uY2hhckNvZGVBdChsKyspLGE9MTtpZigxMD09PXIpdT0hMDtlbHNlIGlm
KDEzPT09cil1PSEwLDEwPT09bi5jaGFyQ29kZUF0KGwpJiYoKytsLCsrYSk7ZWxzZSBpZihyIT09
Yyljb250aW51ZTtyZXR1cm4gbi5zdWJzdHJpbmcodCxsLWEpfXJldHVybiBuLnN1YnN0cmluZyh0
KX1mb3IodmFyIHIsdSxpPXt9LG89e30sYT1bXSxzPW4ubGVuZ3RoLGw9MCxmPTA7KHI9ZSgpKSE9
PW87KXtmb3IodmFyIGg9W107ciE9PWkmJnIhPT1vOyloLnB1c2gocikscj1lKCk7KCF0fHwoaD10
KGgsZisrKSkpJiZhLnB1c2goaCl9cmV0dXJuIGF9LGUuZm9ybWF0PWZ1bmN0aW9uKHQpe2lmKEFy
cmF5LmlzQXJyYXkodFswXSkpcmV0dXJuIGUuZm9ybWF0Um93cyh0KTt2YXIgcj1uZXcgaCx1PVtd
O3JldHVybiB0LmZvckVhY2goZnVuY3Rpb24obil7Zm9yKHZhciB0IGluIG4pci5oYXModCl8fHUu
cHVzaChyLmFkZCh0KSl9KSxbdS5tYXAobykuam9pbihuKV0uY29uY2F0KHQubWFwKGZ1bmN0aW9u
KHQpe3JldHVybiB1Lm1hcChmdW5jdGlvbihuKXtyZXR1cm4gbyh0W25dKX0pLmpvaW4obil9KSku
am9pbigiXG4iKX0sZS5mb3JtYXRSb3dzPWZ1bmN0aW9uKG4pe3JldHVybiBuLm1hcChpKS5qb2lu
KCJcbiIpfSxlfSxHby5jc3Y9R28uZHN2KCIsIiwidGV4dC9jc3YiKSxHby50c3Y9R28uZHN2KCIJ
IiwidGV4dC90YWItc2VwYXJhdGVkLXZhbHVlcyIpLEdvLnRvdWNoPWZ1bmN0aW9uKG4sdCxlKXtp
Zihhcmd1bWVudHMubGVuZ3RoPDMmJihlPXQsdD14KCkuY2hhbmdlZFRvdWNoZXMpLHQpZm9yKHZh
ciByLHU9MCxpPXQubGVuZ3RoO2k+dTsrK3UpaWYoKHI9dFt1XSkuaWRlbnRpZmllcj09PWUpcmV0
dXJuIFoobixyKX07dmFyIFdhLEdhLEthLFFhLG5jLHRjPWVhW3AoZWEsInJlcXVlc3RBbmltYXRp
b25GcmFtZSIpXXx8ZnVuY3Rpb24obil7c2V0VGltZW91dChuLDE3KX07R28udGltZXI9ZnVuY3Rp
b24obix0LGUpe3ZhciByPWFyZ3VtZW50cy5sZW5ndGg7Mj5yJiYodD0wKSwzPnImJihlPURhdGUu
bm93KCkpO3ZhciB1PWUrdCxpPXtjOm4sdDp1LGY6ITEsbjpudWxsfTtHYT9HYS5uPWk6V2E9aSxH
YT1pLEthfHwoUWE9Y2xlYXJUaW1lb3V0KFFhKSxLYT0xLHRjKFR0KSl9LEdvLnRpbWVyLmZsdXNo
PWZ1bmN0aW9uKCl7cXQoKSx6dCgpfSxHby5yb3VuZD1mdW5jdGlvbihuLHQpe3JldHVybiB0P01h
dGgucm91bmQobioodD1NYXRoLnBvdygxMCx0KSkpL3Q6TWF0aC5yb3VuZChuKX07dmFyIGVjPVsi
eSIsInoiLCJhIiwiZiIsInAiLCJuIiwiXHhiNSIsIm0iLCIiLCJrIiwiTSIsIkciLCJUIiwiUCIs
IkUiLCJaIiwiWSJdLm1hcChEdCk7R28uZm9ybWF0UHJlZml4PWZ1bmN0aW9uKG4sdCl7dmFyIGU9
MDtyZXR1cm4gbiYmKDA+biYmKG4qPS0xKSx0JiYobj1Hby5yb3VuZChuLFJ0KG4sdCkpKSxlPTEr
TWF0aC5mbG9vcigxZS0xMitNYXRoLmxvZyhuKS9NYXRoLkxOMTApLGU9TWF0aC5tYXgoLTI0LE1h
dGgubWluKDI0LDMqTWF0aC5mbG9vcigoZS0xKS8zKSkpKSxlY1s4K2UvM119O3ZhciByYz0vKD86
KFtee10pPyhbPD49Xl0pKT8oWytcLSBdKT8oWyQjXSk/KDApPyhcZCspPygsKT8oXC4tP1xkKyk/
KFthLXolXSk/L2ksdWM9R28ubWFwKHtiOmZ1bmN0aW9uKG4pe3JldHVybiBuLnRvU3RyaW5nKDIp
fSxjOmZ1bmN0aW9uKG4pe3JldHVybiBTdHJpbmcuZnJvbUNoYXJDb2RlKG4pfSxvOmZ1bmN0aW9u
KG4pe3JldHVybiBuLnRvU3RyaW5nKDgpfSx4OmZ1bmN0aW9uKG4pe3JldHVybiBuLnRvU3RyaW5n
KDE2KX0sWDpmdW5jdGlvbihuKXtyZXR1cm4gbi50b1N0cmluZygxNikudG9VcHBlckNhc2UoKX0s
ZzpmdW5jdGlvbihuLHQpe3JldHVybiBuLnRvUHJlY2lzaW9uKHQpfSxlOmZ1bmN0aW9uKG4sdCl7
cmV0dXJuIG4udG9FeHBvbmVudGlhbCh0KX0sZjpmdW5jdGlvbihuLHQpe3JldHVybiBuLnRvRml4
ZWQodCl9LHI6ZnVuY3Rpb24obix0KXtyZXR1cm4obj1Hby5yb3VuZChuLFJ0KG4sdCkpKS50b0Zp
eGVkKE1hdGgubWF4KDAsTWF0aC5taW4oMjAsUnQobiooMSsxZS0xNSksdCkpKSl9fSksaWM9R28u
dGltZT17fSxvYz1EYXRlO2p0LnByb3RvdHlwZT17Z2V0RGF0ZTpmdW5jdGlvbigpe3JldHVybiB0
aGlzLl8uZ2V0VVRDRGF0ZSgpfSxnZXREYXk6ZnVuY3Rpb24oKXtyZXR1cm4gdGhpcy5fLmdldFVU
Q0RheSgpfSxnZXRGdWxsWWVhcjpmdW5jdGlvbigpe3JldHVybiB0aGlzLl8uZ2V0VVRDRnVsbFll
YXIoKX0sZ2V0SG91cnM6ZnVuY3Rpb24oKXtyZXR1cm4gdGhpcy5fLmdldFVUQ0hvdXJzKCl9LGdl
dE1pbGxpc2Vjb25kczpmdW5jdGlvbigpe3JldHVybiB0aGlzLl8uZ2V0VVRDTWlsbGlzZWNvbmRz
KCl9LGdldE1pbnV0ZXM6ZnVuY3Rpb24oKXtyZXR1cm4gdGhpcy5fLmdldFVUQ01pbnV0ZXMoKX0s
Z2V0TW9udGg6ZnVuY3Rpb24oKXtyZXR1cm4gdGhpcy5fLmdldFVUQ01vbnRoKCl9LGdldFNlY29u
ZHM6ZnVuY3Rpb24oKXtyZXR1cm4gdGhpcy5fLmdldFVUQ1NlY29uZHMoKX0sZ2V0VGltZTpmdW5j
dGlvbigpe3JldHVybiB0aGlzLl8uZ2V0VGltZSgpfSxnZXRUaW1lem9uZU9mZnNldDpmdW5jdGlv
bigpe3JldHVybiAwfSx2YWx1ZU9mOmZ1bmN0aW9uKCl7cmV0dXJuIHRoaXMuXy52YWx1ZU9mKCl9
LHNldERhdGU6ZnVuY3Rpb24oKXthYy5zZXRVVENEYXRlLmFwcGx5KHRoaXMuXyxhcmd1bWVudHMp
fSxzZXREYXk6ZnVuY3Rpb24oKXthYy5zZXRVVENEYXkuYXBwbHkodGhpcy5fLGFyZ3VtZW50cyl9
LHNldEZ1bGxZZWFyOmZ1bmN0aW9uKCl7YWMuc2V0VVRDRnVsbFllYXIuYXBwbHkodGhpcy5fLGFy
Z3VtZW50cyl9LHNldEhvdXJzOmZ1bmN0aW9uKCl7YWMuc2V0VVRDSG91cnMuYXBwbHkodGhpcy5f
LGFyZ3VtZW50cyl9LHNldE1pbGxpc2Vjb25kczpmdW5jdGlvbigpe2FjLnNldFVUQ01pbGxpc2Vj
b25kcy5hcHBseSh0aGlzLl8sYXJndW1lbnRzKX0sc2V0TWludXRlczpmdW5jdGlvbigpe2FjLnNl
dFVUQ01pbnV0ZXMuYXBwbHkodGhpcy5fLGFyZ3VtZW50cyl9LHNldE1vbnRoOmZ1bmN0aW9uKCl7
YWMuc2V0VVRDTW9udGguYXBwbHkodGhpcy5fLGFyZ3VtZW50cyl9LHNldFNlY29uZHM6ZnVuY3Rp
b24oKXthYy5zZXRVVENTZWNvbmRzLmFwcGx5KHRoaXMuXyxhcmd1bWVudHMpfSxzZXRUaW1lOmZ1
bmN0aW9uKCl7YWMuc2V0VGltZS5hcHBseSh0aGlzLl8sYXJndW1lbnRzKX19O3ZhciBhYz1EYXRl
LnByb3RvdHlwZTtpYy55ZWFyPUh0KGZ1bmN0aW9uKG4pe3JldHVybiBuPWljLmRheShuKSxuLnNl
dE1vbnRoKDAsMSksbn0sZnVuY3Rpb24obix0KXtuLnNldEZ1bGxZZWFyKG4uZ2V0RnVsbFllYXIo
KSt0KX0sZnVuY3Rpb24obil7cmV0dXJuIG4uZ2V0RnVsbFllYXIoKX0pLGljLnllYXJzPWljLnll
YXIucmFuZ2UsaWMueWVhcnMudXRjPWljLnllYXIudXRjLnJhbmdlLGljLmRheT1IdChmdW5jdGlv
bihuKXt2YXIgdD1uZXcgb2MoMmUzLDApO3JldHVybiB0LnNldEZ1bGxZZWFyKG4uZ2V0RnVsbFll
YXIoKSxuLmdldE1vbnRoKCksbi5nZXREYXRlKCkpLHR9LGZ1bmN0aW9uKG4sdCl7bi5zZXREYXRl
KG4uZ2V0RGF0ZSgpK3QpfSxmdW5jdGlvbihuKXtyZXR1cm4gbi5nZXREYXRlKCktMX0pLGljLmRh
eXM9aWMuZGF5LnJhbmdlLGljLmRheXMudXRjPWljLmRheS51dGMucmFuZ2UsaWMuZGF5T2ZZZWFy
PWZ1bmN0aW9uKG4pe3ZhciB0PWljLnllYXIobik7cmV0dXJuIE1hdGguZmxvb3IoKG4tdC02ZTQq
KG4uZ2V0VGltZXpvbmVPZmZzZXQoKS10LmdldFRpbWV6b25lT2Zmc2V0KCkpKS84NjRlNSl9LFsi
c3VuZGF5IiwibW9uZGF5IiwidHVlc2RheSIsIndlZG5lc2RheSIsInRodXJzZGF5IiwiZnJpZGF5
Iiwic2F0dXJkYXkiXS5mb3JFYWNoKGZ1bmN0aW9uKG4sdCl7dD03LXQ7dmFyIGU9aWNbbl09SHQo
ZnVuY3Rpb24obil7cmV0dXJuKG49aWMuZGF5KG4pKS5zZXREYXRlKG4uZ2V0RGF0ZSgpLShuLmdl
dERheSgpK3QpJTcpLG59LGZ1bmN0aW9uKG4sdCl7bi5zZXREYXRlKG4uZ2V0RGF0ZSgpKzcqTWF0
aC5mbG9vcih0KSl9LGZ1bmN0aW9uKG4pe3ZhciBlPWljLnllYXIobikuZ2V0RGF5KCk7cmV0dXJu
IE1hdGguZmxvb3IoKGljLmRheU9mWWVhcihuKSsoZSt0KSU3KS83KS0oZSE9PXQpfSk7aWNbbisi
cyJdPWUucmFuZ2UsaWNbbisicyJdLnV0Yz1lLnV0Yy5yYW5nZSxpY1tuKyJPZlllYXIiXT1mdW5j
dGlvbihuKXt2YXIgZT1pYy55ZWFyKG4pLmdldERheSgpO3JldHVybiBNYXRoLmZsb29yKChpYy5k
YXlPZlllYXIobikrKGUrdCklNykvNyl9fSksaWMud2Vlaz1pYy5zdW5kYXksaWMud2Vla3M9aWMu
c3VuZGF5LnJhbmdlLGljLndlZWtzLnV0Yz1pYy5zdW5kYXkudXRjLnJhbmdlLGljLndlZWtPZlll
YXI9aWMuc3VuZGF5T2ZZZWFyO3ZhciBjYz17Ii0iOiIiLF86IiAiLDA6IjAifSxzYz0vXlxzKlxk
Ky8sbGM9L14lLztHby5sb2NhbGU9ZnVuY3Rpb24obil7cmV0dXJue251bWJlckZvcm1hdDpQdChu
KSx0aW1lRm9ybWF0Ok90KG4pfX07dmFyIGZjPUdvLmxvY2FsZSh7ZGVjaW1hbDoiLiIsdGhvdXNh
bmRzOiIsIixncm91cGluZzpbM10sY3VycmVuY3k6WyIkIiwiIl0sZGF0ZVRpbWU6IiVhICViICVl
ICVYICVZIixkYXRlOiIlbS8lZC8lWSIsdGltZToiJUg6JU06JVMiLHBlcmlvZHM6WyJBTSIsIlBN
Il0sZGF5czpbIlN1bmRheSIsIk1vbmRheSIsIlR1ZXNkYXkiLCJXZWRuZXNkYXkiLCJUaHVyc2Rh
eSIsIkZyaWRheSIsIlNhdHVyZGF5Il0sc2hvcnREYXlzOlsiU3VuIiwiTW9uIiwiVHVlIiwiV2Vk
IiwiVGh1IiwiRnJpIiwiU2F0Il0sbW9udGhzOlsiSmFudWFyeSIsIkZlYnJ1YXJ5IiwiTWFyY2gi
LCJBcHJpbCIsIk1heSIsIkp1bmUiLCJKdWx5IiwiQXVndXN0IiwiU2VwdGVtYmVyIiwiT2N0b2Jl
ciIsIk5vdmVtYmVyIiwiRGVjZW1iZXIiXSxzaG9ydE1vbnRoczpbIkphbiIsIkZlYiIsIk1hciIs
IkFwciIsIk1heSIsIkp1biIsIkp1bCIsIkF1ZyIsIlNlcCIsIk9jdCIsIk5vdiIsIkRlYyJdfSk7
R28uZm9ybWF0PWZjLm51bWJlckZvcm1hdCxHby5nZW89e30sY2UucHJvdG90eXBlPXtzOjAsdDow
LGFkZDpmdW5jdGlvbihuKXtzZShuLHRoaXMudCxoYyksc2UoaGMucyx0aGlzLnMsdGhpcyksdGhp
cy5zP3RoaXMudCs9aGMudDp0aGlzLnM9aGMudH0scmVzZXQ6ZnVuY3Rpb24oKXt0aGlzLnM9dGhp
cy50PTB9LHZhbHVlT2Y6ZnVuY3Rpb24oKXtyZXR1cm4gdGhpcy5zfX07dmFyIGhjPW5ldyBjZTtH
by5nZW8uc3RyZWFtPWZ1bmN0aW9uKG4sdCl7biYmZ2MuaGFzT3duUHJvcGVydHkobi50eXBlKT9n
Y1tuLnR5cGVdKG4sdCk6bGUobix0KX07dmFyIGdjPXtGZWF0dXJlOmZ1bmN0aW9uKG4sdCl7bGUo
bi5nZW9tZXRyeSx0KX0sRmVhdHVyZUNvbGxlY3Rpb246ZnVuY3Rpb24obix0KXtmb3IodmFyIGU9
bi5mZWF0dXJlcyxyPS0xLHU9ZS5sZW5ndGg7KytyPHU7KWxlKGVbcl0uZ2VvbWV0cnksdCl9fSxw
Yz17U3BoZXJlOmZ1bmN0aW9uKG4sdCl7dC5zcGhlcmUoKX0sUG9pbnQ6ZnVuY3Rpb24obix0KXtu
PW4uY29vcmRpbmF0ZXMsdC5wb2ludChuWzBdLG5bMV0sblsyXSl9LE11bHRpUG9pbnQ6ZnVuY3Rp
b24obix0KXtmb3IodmFyIGU9bi5jb29yZGluYXRlcyxyPS0xLHU9ZS5sZW5ndGg7KytyPHU7KW49
ZVtyXSx0LnBvaW50KG5bMF0sblsxXSxuWzJdKX0sTGluZVN0cmluZzpmdW5jdGlvbihuLHQpe2Zl
KG4uY29vcmRpbmF0ZXMsdCwwKX0sTXVsdGlMaW5lU3RyaW5nOmZ1bmN0aW9uKG4sdCl7Zm9yKHZh
ciBlPW4uY29vcmRpbmF0ZXMscj0tMSx1PWUubGVuZ3RoOysrcjx1OylmZShlW3JdLHQsMCl9LFBv
bHlnb246ZnVuY3Rpb24obix0KXtoZShuLmNvb3JkaW5hdGVzLHQpfSxNdWx0aVBvbHlnb246ZnVu
Y3Rpb24obix0KXtmb3IodmFyIGU9bi5jb29yZGluYXRlcyxyPS0xLHU9ZS5sZW5ndGg7KytyPHU7
KWhlKGVbcl0sdCl9LEdlb21ldHJ5Q29sbGVjdGlvbjpmdW5jdGlvbihuLHQpe2Zvcih2YXIgZT1u
Lmdlb21ldHJpZXMscj0tMSx1PWUubGVuZ3RoOysrcjx1OylsZShlW3JdLHQpfX07R28uZ2VvLmFy
ZWE9ZnVuY3Rpb24obil7cmV0dXJuIHZjPTAsR28uZ2VvLnN0cmVhbShuLG1jKSx2Y307dmFyIHZj
LGRjPW5ldyBjZSxtYz17c3BoZXJlOmZ1bmN0aW9uKCl7dmMrPTQqQ2F9LHBvaW50OnYsbGluZVN0
YXJ0OnYsbGluZUVuZDp2LHBvbHlnb25TdGFydDpmdW5jdGlvbigpe2RjLnJlc2V0KCksbWMubGlu
ZVN0YXJ0PWdlfSxwb2x5Z29uRW5kOmZ1bmN0aW9uKCl7dmFyIG49MipkYzt2Yys9MD5uPzQqQ2Er
bjpuLG1jLmxpbmVTdGFydD1tYy5saW5lRW5kPW1jLnBvaW50PXZ9fTtHby5nZW8uYm91bmRzPWZ1
bmN0aW9uKCl7ZnVuY3Rpb24gbihuLHQpe3gucHVzaChNPVtsPW4saD1uXSksZj50JiYoZj10KSx0
PmcmJihnPXQpfWZ1bmN0aW9uIHQodCxlKXt2YXIgcj1wZShbdCp6YSxlKnphXSk7aWYobSl7dmFy
IHU9ZGUobSxyKSxpPVt1WzFdLC11WzBdLDBdLG89ZGUoaSx1KTt4ZShvKSxvPU1lKG8pO3ZhciBj
PXQtcCxzPWM+MD8xOi0xLHY9b1swXSpSYSpzLGQ9ZmEoYyk+MTgwO2lmKGReKHY+cypwJiZzKnQ+
dikpe3ZhciB5PW9bMV0qUmE7eT5nJiYoZz15KX1lbHNlIGlmKHY9KHYrMzYwKSUzNjAtMTgwLGRe
KHY+cypwJiZzKnQ+dikpe3ZhciB5PS1vWzFdKlJhO2Y+eSYmKGY9eSl9ZWxzZSBmPmUmJihmPWUp
LGU+ZyYmKGc9ZSk7ZD9wPnQ/YShsLHQpPmEobCxoKSYmKGg9dCk6YSh0LGgpPmEobCxoKSYmKGw9
dCk6aD49bD8obD50JiYobD10KSx0PmgmJihoPXQpKTp0PnA/YShsLHQpPmEobCxoKSYmKGg9dCk6
YSh0LGgpPmEobCxoKSYmKGw9dCl9ZWxzZSBuKHQsZSk7bT1yLHA9dH1mdW5jdGlvbiBlKCl7Xy5w
b2ludD10fWZ1bmN0aW9uIHIoKXtNWzBdPWwsTVsxXT1oLF8ucG9pbnQ9bixtPW51bGx9ZnVuY3Rp
b24gdShuLGUpe2lmKG0pe3ZhciByPW4tcDt5Kz1mYShyKT4xODA/cisocj4wPzM2MDotMzYwKTpy
fWVsc2Ugdj1uLGQ9ZTttYy5wb2ludChuLGUpLHQobixlKX1mdW5jdGlvbiBpKCl7bWMubGluZVN0
YXJ0KCl9ZnVuY3Rpb24gbygpe3UodixkKSxtYy5saW5lRW5kKCksZmEoeSk+VGEmJihsPS0oaD0x
ODApKSxNWzBdPWwsTVsxXT1oLG09bnVsbH1mdW5jdGlvbiBhKG4sdCl7cmV0dXJuKHQtPW4pPDA/
dCszNjA6dH1mdW5jdGlvbiBjKG4sdCl7cmV0dXJuIG5bMF0tdFswXX1mdW5jdGlvbiBzKG4sdCl7
cmV0dXJuIHRbMF08PXRbMV0/dFswXTw9biYmbjw9dFsxXTpuPHRbMF18fHRbMV08bn12YXIgbCxm
LGgsZyxwLHYsZCxtLHkseCxNLF89e3BvaW50Om4sbGluZVN0YXJ0OmUsbGluZUVuZDpyLHBvbHln
b25TdGFydDpmdW5jdGlvbigpe18ucG9pbnQ9dSxfLmxpbmVTdGFydD1pLF8ubGluZUVuZD1vLHk9
MCxtYy5wb2x5Z29uU3RhcnQoKX0scG9seWdvbkVuZDpmdW5jdGlvbigpe21jLnBvbHlnb25FbmQo
KSxfLnBvaW50PW4sXy5saW5lU3RhcnQ9ZSxfLmxpbmVFbmQ9ciwwPmRjPyhsPS0oaD0xODApLGY9
LShnPTkwKSk6eT5UYT9nPTkwOi1UYT55JiYoZj0tOTApLE1bMF09bCxNWzFdPWh9fTtyZXR1cm4g
ZnVuY3Rpb24obil7Zz1oPS0obD1mPTEvMCkseD1bXSxHby5nZW8uc3RyZWFtKG4sXyk7dmFyIHQ9
eC5sZW5ndGg7aWYodCl7eC5zb3J0KGMpO2Zvcih2YXIgZSxyPTEsdT14WzBdLGk9W3VdO3Q+cjsr
K3IpZT14W3JdLHMoZVswXSx1KXx8cyhlWzFdLHUpPyhhKHVbMF0sZVsxXSk+YSh1WzBdLHVbMV0p
JiYodVsxXT1lWzFdKSxhKGVbMF0sdVsxXSk+YSh1WzBdLHVbMV0pJiYodVswXT1lWzBdKSk6aS5w
dXNoKHU9ZSk7CmZvcih2YXIgbyxlLHA9LTEvMCx0PWkubGVuZ3RoLTEscj0wLHU9aVt0XTt0Pj1y
O3U9ZSwrK3IpZT1pW3JdLChvPWEodVsxXSxlWzBdKSk+cCYmKHA9byxsPWVbMF0saD11WzFdKX1y
ZXR1cm4geD1NPW51bGwsMS8wPT09bHx8MS8wPT09Zj9bWzAvMCwwLzBdLFswLzAsMC8wXV06W1ts
LGZdLFtoLGddXX19KCksR28uZ2VvLmNlbnRyb2lkPWZ1bmN0aW9uKG4pe3ljPXhjPU1jPV9jPWJj
PXdjPVNjPWtjPUVjPUFjPUNjPTAsR28uZ2VvLnN0cmVhbShuLE5jKTt2YXIgdD1FYyxlPUFjLHI9
Q2MsdT10KnQrZSplK3IqcjtyZXR1cm4gcWE+dSYmKHQ9d2MsZT1TYyxyPWtjLFRhPnhjJiYodD1N
YyxlPV9jLHI9YmMpLHU9dCp0K2UqZStyKnIscWE+dSk/WzAvMCwwLzBdOltNYXRoLmF0YW4yKGUs
dCkqUmEsRyhyL01hdGguc3FydCh1KSkqUmFdfTt2YXIgeWMseGMsTWMsX2MsYmMsd2MsU2Msa2Ms
RWMsQWMsQ2MsTmM9e3NwaGVyZTp2LHBvaW50OmJlLGxpbmVTdGFydDpTZSxsaW5lRW5kOmtlLHBv
bHlnb25TdGFydDpmdW5jdGlvbigpe05jLmxpbmVTdGFydD1FZX0scG9seWdvbkVuZDpmdW5jdGlv
bigpe05jLmxpbmVTdGFydD1TZX19LExjPVRlKEFlLFBlLGplLFstQ2EsLUNhLzJdKSxUYz0xZTk7
R28uZ2VvLmNsaXBFeHRlbnQ9ZnVuY3Rpb24oKXt2YXIgbix0LGUscix1LGksbz17c3RyZWFtOmZ1
bmN0aW9uKG4pe3JldHVybiB1JiYodS52YWxpZD0hMSksdT1pKG4pLHUudmFsaWQ9ITAsdX0sZXh0
ZW50OmZ1bmN0aW9uKGEpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhpPU9lKG49K2FbMF1bMF0s
dD0rYVswXVsxXSxlPSthWzFdWzBdLHI9K2FbMV1bMV0pLHUmJih1LnZhbGlkPSExLHU9bnVsbCks
byk6W1tuLHRdLFtlLHJdXX19O3JldHVybiBvLmV4dGVudChbWzAsMF0sWzk2MCw1MDBdXSl9LChH
by5nZW8uY29uaWNFcXVhbEFyZWE9ZnVuY3Rpb24oKXtyZXR1cm4gWWUoWmUpfSkucmF3PVplLEdv
Lmdlby5hbGJlcnM9ZnVuY3Rpb24oKXtyZXR1cm4gR28uZ2VvLmNvbmljRXF1YWxBcmVhKCkucm90
YXRlKFs5NiwwXSkuY2VudGVyKFstLjYsMzguN10pLnBhcmFsbGVscyhbMjkuNSw0NS41XSkuc2Nh
bGUoMTA3MCl9LEdvLmdlby5hbGJlcnNVc2E9ZnVuY3Rpb24oKXtmdW5jdGlvbiBuKG4pe3ZhciBp
PW5bMF0sbz1uWzFdO3JldHVybiB0PW51bGwsZShpLG8pLHR8fChyKGksbyksdCl8fHUoaSxvKSx0
fXZhciB0LGUscix1LGk9R28uZ2VvLmFsYmVycygpLG89R28uZ2VvLmNvbmljRXF1YWxBcmVhKCku
cm90YXRlKFsxNTQsMF0pLmNlbnRlcihbLTIsNTguNV0pLnBhcmFsbGVscyhbNTUsNjVdKSxhPUdv
Lmdlby5jb25pY0VxdWFsQXJlYSgpLnJvdGF0ZShbMTU3LDBdKS5jZW50ZXIoWy0zLDE5LjldKS5w
YXJhbGxlbHMoWzgsMThdKSxjPXtwb2ludDpmdW5jdGlvbihuLGUpe3Q9W24sZV19fTtyZXR1cm4g
bi5pbnZlcnQ9ZnVuY3Rpb24obil7dmFyIHQ9aS5zY2FsZSgpLGU9aS50cmFuc2xhdGUoKSxyPShu
WzBdLWVbMF0pL3QsdT0oblsxXS1lWzFdKS90O3JldHVybih1Pj0uMTImJi4yMzQ+dSYmcj49LS40
MjUmJi0uMjE0PnI/bzp1Pj0uMTY2JiYuMjM0PnUmJnI+PS0uMjE0JiYtLjExNT5yP2E6aSkuaW52
ZXJ0KG4pfSxuLnN0cmVhbT1mdW5jdGlvbihuKXt2YXIgdD1pLnN0cmVhbShuKSxlPW8uc3RyZWFt
KG4pLHI9YS5zdHJlYW0obik7cmV0dXJue3BvaW50OmZ1bmN0aW9uKG4sdSl7dC5wb2ludChuLHUp
LGUucG9pbnQobix1KSxyLnBvaW50KG4sdSl9LHNwaGVyZTpmdW5jdGlvbigpe3Quc3BoZXJlKCks
ZS5zcGhlcmUoKSxyLnNwaGVyZSgpfSxsaW5lU3RhcnQ6ZnVuY3Rpb24oKXt0LmxpbmVTdGFydCgp
LGUubGluZVN0YXJ0KCksci5saW5lU3RhcnQoKX0sbGluZUVuZDpmdW5jdGlvbigpe3QubGluZUVu
ZCgpLGUubGluZUVuZCgpLHIubGluZUVuZCgpfSxwb2x5Z29uU3RhcnQ6ZnVuY3Rpb24oKXt0LnBv
bHlnb25TdGFydCgpLGUucG9seWdvblN0YXJ0KCksci5wb2x5Z29uU3RhcnQoKX0scG9seWdvbkVu
ZDpmdW5jdGlvbigpe3QucG9seWdvbkVuZCgpLGUucG9seWdvbkVuZCgpLHIucG9seWdvbkVuZCgp
fX19LG4ucHJlY2lzaW9uPWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhpLnBy
ZWNpc2lvbih0KSxvLnByZWNpc2lvbih0KSxhLnByZWNpc2lvbih0KSxuKTppLnByZWNpc2lvbigp
fSxuLnNjYWxlPWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhpLnNjYWxlKHQp
LG8uc2NhbGUoLjM1KnQpLGEuc2NhbGUodCksbi50cmFuc2xhdGUoaS50cmFuc2xhdGUoKSkpOmku
c2NhbGUoKX0sbi50cmFuc2xhdGU9ZnVuY3Rpb24odCl7aWYoIWFyZ3VtZW50cy5sZW5ndGgpcmV0
dXJuIGkudHJhbnNsYXRlKCk7dmFyIHM9aS5zY2FsZSgpLGw9K3RbMF0sZj0rdFsxXTtyZXR1cm4g
ZT1pLnRyYW5zbGF0ZSh0KS5jbGlwRXh0ZW50KFtbbC0uNDU1KnMsZi0uMjM4KnNdLFtsKy40NTUq
cyxmKy4yMzgqc11dKS5zdHJlYW0oYykucG9pbnQscj1vLnRyYW5zbGF0ZShbbC0uMzA3KnMsZisu
MjAxKnNdKS5jbGlwRXh0ZW50KFtbbC0uNDI1KnMrVGEsZisuMTIqcytUYV0sW2wtLjIxNCpzLVRh
LGYrLjIzNCpzLVRhXV0pLnN0cmVhbShjKS5wb2ludCx1PWEudHJhbnNsYXRlKFtsLS4yMDUqcyxm
Ky4yMTIqc10pLmNsaXBFeHRlbnQoW1tsLS4yMTQqcytUYSxmKy4xNjYqcytUYV0sW2wtLjExNSpz
LVRhLGYrLjIzNCpzLVRhXV0pLnN0cmVhbShjKS5wb2ludCxufSxuLnNjYWxlKDEwNzApfTt2YXIg
cWMsemMsUmMsRGMsUGMsVWMsamM9e3BvaW50OnYsbGluZVN0YXJ0OnYsbGluZUVuZDp2LHBvbHln
b25TdGFydDpmdW5jdGlvbigpe3pjPTAsamMubGluZVN0YXJ0PVZlfSxwb2x5Z29uRW5kOmZ1bmN0
aW9uKCl7amMubGluZVN0YXJ0PWpjLmxpbmVFbmQ9amMucG9pbnQ9dixxYys9ZmEoemMvMil9fSxI
Yz17cG9pbnQ6JGUsbGluZVN0YXJ0OnYsbGluZUVuZDp2LHBvbHlnb25TdGFydDp2LHBvbHlnb25F
bmQ6dn0sRmM9e3BvaW50OkplLGxpbmVTdGFydDpXZSxsaW5lRW5kOkdlLHBvbHlnb25TdGFydDpm
dW5jdGlvbigpe0ZjLmxpbmVTdGFydD1LZX0scG9seWdvbkVuZDpmdW5jdGlvbigpe0ZjLnBvaW50
PUplLEZjLmxpbmVTdGFydD1XZSxGYy5saW5lRW5kPUdlfX07R28uZ2VvLnBhdGg9ZnVuY3Rpb24o
KXtmdW5jdGlvbiBuKG4pe3JldHVybiBuJiYoImZ1bmN0aW9uIj09dHlwZW9mIGEmJmkucG9pbnRS
YWRpdXMoK2EuYXBwbHkodGhpcyxhcmd1bWVudHMpKSxvJiZvLnZhbGlkfHwobz11KGkpKSxHby5n
ZW8uc3RyZWFtKG4sbykpLGkucmVzdWx0KCl9ZnVuY3Rpb24gdCgpe3JldHVybiBvPW51bGwsbn12
YXIgZSxyLHUsaSxvLGE9NC41O3JldHVybiBuLmFyZWE9ZnVuY3Rpb24obil7cmV0dXJuIHFjPTAs
R28uZ2VvLnN0cmVhbShuLHUoamMpKSxxY30sbi5jZW50cm9pZD1mdW5jdGlvbihuKXtyZXR1cm4g
TWM9X2M9YmM9d2M9U2M9a2M9RWM9QWM9Q2M9MCxHby5nZW8uc3RyZWFtKG4sdShGYykpLENjP1tF
Yy9DYyxBYy9DY106a2M/W3djL2tjLFNjL2tjXTpiYz9bTWMvYmMsX2MvYmNdOlswLzAsMC8wXX0s
bi5ib3VuZHM9ZnVuY3Rpb24obil7cmV0dXJuIFBjPVVjPS0oUmM9RGM9MS8wKSxHby5nZW8uc3Ry
ZWFtKG4sdShIYykpLFtbUmMsRGNdLFtQYyxVY11dfSxuLnByb2plY3Rpb249ZnVuY3Rpb24obil7
cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KHU9KGU9bik/bi5zdHJlYW18fHRyKG4pOkF0LHQoKSk6
ZX0sbi5jb250ZXh0PWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhpPW51bGw9
PShyPW4pP25ldyBYZTpuZXcgUWUobiksImZ1bmN0aW9uIiE9dHlwZW9mIGEmJmkucG9pbnRSYWRp
dXMoYSksdCgpKTpyfSxuLnBvaW50UmFkaXVzPWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMu
bGVuZ3RoPyhhPSJmdW5jdGlvbiI9PXR5cGVvZiB0P3Q6KGkucG9pbnRSYWRpdXMoK3QpLCt0KSxu
KTphfSxuLnByb2plY3Rpb24oR28uZ2VvLmFsYmVyc1VzYSgpKS5jb250ZXh0KG51bGwpfSxHby5n
ZW8udHJhbnNmb3JtPWZ1bmN0aW9uKG4pe3JldHVybntzdHJlYW06ZnVuY3Rpb24odCl7dmFyIGU9
bmV3IGVyKHQpO2Zvcih2YXIgciBpbiBuKWVbcl09bltyXTtyZXR1cm4gZX19fSxlci5wcm90b3R5
cGU9e3BvaW50OmZ1bmN0aW9uKG4sdCl7dGhpcy5zdHJlYW0ucG9pbnQobix0KX0sc3BoZXJlOmZ1
bmN0aW9uKCl7dGhpcy5zdHJlYW0uc3BoZXJlKCl9LGxpbmVTdGFydDpmdW5jdGlvbigpe3RoaXMu
c3RyZWFtLmxpbmVTdGFydCgpfSxsaW5lRW5kOmZ1bmN0aW9uKCl7dGhpcy5zdHJlYW0ubGluZUVu
ZCgpfSxwb2x5Z29uU3RhcnQ6ZnVuY3Rpb24oKXt0aGlzLnN0cmVhbS5wb2x5Z29uU3RhcnQoKX0s
cG9seWdvbkVuZDpmdW5jdGlvbigpe3RoaXMuc3RyZWFtLnBvbHlnb25FbmQoKX19LEdvLmdlby5w
cm9qZWN0aW9uPXVyLEdvLmdlby5wcm9qZWN0aW9uTXV0YXRvcj1pciwoR28uZ2VvLmVxdWlyZWN0
YW5ndWxhcj1mdW5jdGlvbigpe3JldHVybiB1cihhcil9KS5yYXc9YXIuaW52ZXJ0PWFyLEdvLmdl
by5yb3RhdGlvbj1mdW5jdGlvbihuKXtmdW5jdGlvbiB0KHQpe3JldHVybiB0PW4odFswXSp6YSx0
WzFdKnphKSx0WzBdKj1SYSx0WzFdKj1SYSx0fXJldHVybiBuPXNyKG5bMF0lMzYwKnphLG5bMV0q
emEsbi5sZW5ndGg+Mj9uWzJdKnphOjApLHQuaW52ZXJ0PWZ1bmN0aW9uKHQpe3JldHVybiB0PW4u
aW52ZXJ0KHRbMF0qemEsdFsxXSp6YSksdFswXSo9UmEsdFsxXSo9UmEsdH0sdH0sY3IuaW52ZXJ0
PWFyLEdvLmdlby5jaXJjbGU9ZnVuY3Rpb24oKXtmdW5jdGlvbiBuKCl7dmFyIG49ImZ1bmN0aW9u
Ij09dHlwZW9mIHI/ci5hcHBseSh0aGlzLGFyZ3VtZW50cyk6cix0PXNyKC1uWzBdKnphLC1uWzFd
KnphLDApLmludmVydCx1PVtdO3JldHVybiBlKG51bGwsbnVsbCwxLHtwb2ludDpmdW5jdGlvbihu
LGUpe3UucHVzaChuPXQobixlKSksblswXSo9UmEsblsxXSo9UmF9fSkse3R5cGU6IlBvbHlnb24i
LGNvb3JkaW5hdGVzOlt1XX19dmFyIHQsZSxyPVswLDBdLHU9NjtyZXR1cm4gbi5vcmlnaW49ZnVu
Y3Rpb24odCl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KHI9dCxuKTpyfSxuLmFuZ2xlPWZ1bmN0
aW9uKHIpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhlPWdyKCh0PStyKSp6YSx1KnphKSxuKTp0
fSxuLnByZWNpc2lvbj1mdW5jdGlvbihyKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oZT1ncih0
KnphLCh1PStyKSp6YSksbik6dX0sbi5hbmdsZSg5MCl9LEdvLmdlby5kaXN0YW5jZT1mdW5jdGlv
bihuLHQpe3ZhciBlLHI9KHRbMF0tblswXSkqemEsdT1uWzFdKnphLGk9dFsxXSp6YSxvPU1hdGgu
c2luKHIpLGE9TWF0aC5jb3MociksYz1NYXRoLnNpbih1KSxzPU1hdGguY29zKHUpLGw9TWF0aC5z
aW4oaSksZj1NYXRoLmNvcyhpKTtyZXR1cm4gTWF0aC5hdGFuMihNYXRoLnNxcnQoKGU9ZipvKSpl
KyhlPXMqbC1jKmYqYSkqZSksYypsK3MqZiphKX0sR28uZ2VvLmdyYXRpY3VsZT1mdW5jdGlvbigp
e2Z1bmN0aW9uIG4oKXtyZXR1cm57dHlwZToiTXVsdGlMaW5lU3RyaW5nIixjb29yZGluYXRlczp0
KCl9fWZ1bmN0aW9uIHQoKXtyZXR1cm4gR28ucmFuZ2UoTWF0aC5jZWlsKGkvZCkqZCx1LGQpLm1h
cChoKS5jb25jYXQoR28ucmFuZ2UoTWF0aC5jZWlsKHMvbSkqbSxjLG0pLm1hcChnKSkuY29uY2F0
KEdvLnJhbmdlKE1hdGguY2VpbChyL3ApKnAsZSxwKS5maWx0ZXIoZnVuY3Rpb24obil7cmV0dXJu
IGZhKG4lZCk+VGF9KS5tYXAobCkpLmNvbmNhdChHby5yYW5nZShNYXRoLmNlaWwoYS92KSp2LG8s
dikuZmlsdGVyKGZ1bmN0aW9uKG4pe3JldHVybiBmYShuJW0pPlRhfSkubWFwKGYpKX12YXIgZSxy
LHUsaSxvLGEsYyxzLGwsZixoLGcscD0xMCx2PXAsZD05MCxtPTM2MCx5PTIuNTtyZXR1cm4gbi5s
aW5lcz1mdW5jdGlvbigpe3JldHVybiB0KCkubWFwKGZ1bmN0aW9uKG4pe3JldHVybnt0eXBlOiJM
aW5lU3RyaW5nIixjb29yZGluYXRlczpufX0pfSxuLm91dGxpbmU9ZnVuY3Rpb24oKXtyZXR1cm57
dHlwZToiUG9seWdvbiIsY29vcmRpbmF0ZXM6W2goaSkuY29uY2F0KGcoYykuc2xpY2UoMSksaCh1
KS5yZXZlcnNlKCkuc2xpY2UoMSksZyhzKS5yZXZlcnNlKCkuc2xpY2UoMSkpXX19LG4uZXh0ZW50
PWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoP24ubWFqb3JFeHRlbnQodCkubWlu
b3JFeHRlbnQodCk6bi5taW5vckV4dGVudCgpfSxuLm1ham9yRXh0ZW50PWZ1bmN0aW9uKHQpe3Jl
dHVybiBhcmd1bWVudHMubGVuZ3RoPyhpPSt0WzBdWzBdLHU9K3RbMV1bMF0scz0rdFswXVsxXSxj
PSt0WzFdWzFdLGk+dSYmKHQ9aSxpPXUsdT10KSxzPmMmJih0PXMscz1jLGM9dCksbi5wcmVjaXNp
b24oeSkpOltbaSxzXSxbdSxjXV19LG4ubWlub3JFeHRlbnQ9ZnVuY3Rpb24odCl7cmV0dXJuIGFy
Z3VtZW50cy5sZW5ndGg/KHI9K3RbMF1bMF0sZT0rdFsxXVswXSxhPSt0WzBdWzFdLG89K3RbMV1b
MV0scj5lJiYodD1yLHI9ZSxlPXQpLGE+byYmKHQ9YSxhPW8sbz10KSxuLnByZWNpc2lvbih5KSk6
W1tyLGFdLFtlLG9dXX0sbi5zdGVwPWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3Ro
P24ubWFqb3JTdGVwKHQpLm1pbm9yU3RlcCh0KTpuLm1pbm9yU3RlcCgpfSxuLm1ham9yU3RlcD1m
dW5jdGlvbih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oZD0rdFswXSxtPSt0WzFdLG4pOltk
LG1dfSxuLm1pbm9yU3RlcD1mdW5jdGlvbih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8ocD0r
dFswXSx2PSt0WzFdLG4pOltwLHZdfSxuLnByZWNpc2lvbj1mdW5jdGlvbih0KXtyZXR1cm4gYXJn
dW1lbnRzLmxlbmd0aD8oeT0rdCxsPXZyKGEsbyw5MCksZj1kcihyLGUseSksaD12cihzLGMsOTAp
LGc9ZHIoaSx1LHkpLG4pOnl9LG4ubWFqb3JFeHRlbnQoW1stMTgwLC05MCtUYV0sWzE4MCw5MC1U
YV1dKS5taW5vckV4dGVudChbWy0xODAsLTgwLVRhXSxbMTgwLDgwK1RhXV0pfSxHby5nZW8uZ3Jl
YXRBcmM9ZnVuY3Rpb24oKXtmdW5jdGlvbiBuKCl7cmV0dXJue3R5cGU6IkxpbmVTdHJpbmciLGNv
b3JkaW5hdGVzOlt0fHxyLmFwcGx5KHRoaXMsYXJndW1lbnRzKSxlfHx1LmFwcGx5KHRoaXMsYXJn
dW1lbnRzKV19fXZhciB0LGUscj1tcix1PXlyO3JldHVybiBuLmRpc3RhbmNlPWZ1bmN0aW9uKCl7
cmV0dXJuIEdvLmdlby5kaXN0YW5jZSh0fHxyLmFwcGx5KHRoaXMsYXJndW1lbnRzKSxlfHx1LmFw
cGx5KHRoaXMsYXJndW1lbnRzKSl9LG4uc291cmNlPWZ1bmN0aW9uKGUpe3JldHVybiBhcmd1bWVu
dHMubGVuZ3RoPyhyPWUsdD0iZnVuY3Rpb24iPT10eXBlb2YgZT9udWxsOmUsbik6cn0sbi50YXJn
ZXQ9ZnVuY3Rpb24odCl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KHU9dCxlPSJmdW5jdGlvbiI9
PXR5cGVvZiB0P251bGw6dCxuKTp1fSxuLnByZWNpc2lvbj1mdW5jdGlvbigpe3JldHVybiBhcmd1
bWVudHMubGVuZ3RoP246MH0sbn0sR28uZ2VvLmludGVycG9sYXRlPWZ1bmN0aW9uKG4sdCl7cmV0
dXJuIHhyKG5bMF0qemEsblsxXSp6YSx0WzBdKnphLHRbMV0qemEpfSxHby5nZW8ubGVuZ3RoPWZ1
bmN0aW9uKG4pe3JldHVybiBPYz0wLEdvLmdlby5zdHJlYW0obixJYyksT2N9O3ZhciBPYyxJYz17
c3BoZXJlOnYscG9pbnQ6dixsaW5lU3RhcnQ6TXIsbGluZUVuZDp2LHBvbHlnb25TdGFydDp2LHBv
bHlnb25FbmQ6dn0sWWM9X3IoZnVuY3Rpb24obil7cmV0dXJuIE1hdGguc3FydCgyLygxK24pKX0s
ZnVuY3Rpb24obil7cmV0dXJuIDIqTWF0aC5hc2luKG4vMil9KTsoR28uZ2VvLmF6aW11dGhhbEVx
dWFsQXJlYT1mdW5jdGlvbigpe3JldHVybiB1cihZYyl9KS5yYXc9WWM7dmFyIFpjPV9yKGZ1bmN0
aW9uKG4pe3ZhciB0PU1hdGguYWNvcyhuKTtyZXR1cm4gdCYmdC9NYXRoLnNpbih0KX0sQXQpOyhH
by5nZW8uYXppbXV0aGFsRXF1aWRpc3RhbnQ9ZnVuY3Rpb24oKXtyZXR1cm4gdXIoWmMpfSkucmF3
PVpjLChHby5nZW8uY29uaWNDb25mb3JtYWw9ZnVuY3Rpb24oKXtyZXR1cm4gWWUoYnIpfSkucmF3
PWJyLChHby5nZW8uY29uaWNFcXVpZGlzdGFudD1mdW5jdGlvbigpe3JldHVybiBZZSh3cil9KS5y
YXc9d3I7dmFyIFZjPV9yKGZ1bmN0aW9uKG4pe3JldHVybiAxL259LE1hdGguYXRhbik7KEdvLmdl
by5nbm9tb25pYz1mdW5jdGlvbigpe3JldHVybiB1cihWYyl9KS5yYXc9VmMsU3IuaW52ZXJ0PWZ1
bmN0aW9uKG4sdCl7cmV0dXJuW24sMipNYXRoLmF0YW4oTWF0aC5leHAodCkpLUxhXX0sKEdvLmdl
by5tZXJjYXRvcj1mdW5jdGlvbigpe3JldHVybiBrcihTcil9KS5yYXc9U3I7dmFyICRjPV9yKGZ1
bmN0aW9uKCl7cmV0dXJuIDF9LE1hdGguYXNpbik7KEdvLmdlby5vcnRob2dyYXBoaWM9ZnVuY3Rp
b24oKXtyZXR1cm4gdXIoJGMpfSkucmF3PSRjO3ZhciBYYz1fcihmdW5jdGlvbihuKXtyZXR1cm4g
MS8oMStuKX0sZnVuY3Rpb24obil7cmV0dXJuIDIqTWF0aC5hdGFuKG4pfSk7KEdvLmdlby5zdGVy
ZW9ncmFwaGljPWZ1bmN0aW9uKCl7cmV0dXJuIHVyKFhjKX0pLnJhdz1YYyxFci5pbnZlcnQ9ZnVu
Y3Rpb24obix0KXtyZXR1cm5bLXQsMipNYXRoLmF0YW4oTWF0aC5leHAobikpLUxhXX0sKEdvLmdl
by50cmFuc3ZlcnNlTWVyY2F0b3I9ZnVuY3Rpb24oKXt2YXIgbj1rcihFciksdD1uLmNlbnRlcixl
PW4ucm90YXRlO3JldHVybiBuLmNlbnRlcj1mdW5jdGlvbihuKXtyZXR1cm4gbj90KFstblsxXSxu
WzBdXSk6KG49dCgpLFstblsxXSxuWzBdXSl9LG4ucm90YXRlPWZ1bmN0aW9uKG4pe3JldHVybiBu
P2UoW25bMF0sblsxXSxuLmxlbmd0aD4yP25bMl0rOTA6OTBdKToobj1lKCksW25bMF0sblsxXSxu
WzJdLTkwXSl9LG4ucm90YXRlKFswLDBdKX0pLnJhdz1FcixHby5nZW9tPXt9LEdvLmdlb20uaHVs
bD1mdW5jdGlvbihuKXtmdW5jdGlvbiB0KG4pe2lmKG4ubGVuZ3RoPDMpcmV0dXJuW107dmFyIHQs
dT1FdChlKSxpPUV0KHIpLG89bi5sZW5ndGgsYT1bXSxjPVtdO2Zvcih0PTA7bz50O3QrKylhLnB1
c2goWyt1LmNhbGwodGhpcyxuW3RdLHQpLCtpLmNhbGwodGhpcyxuW3RdLHQpLHRdKTtmb3IoYS5z
b3J0KExyKSx0PTA7bz50O3QrKyljLnB1c2goW2FbdF1bMF0sLWFbdF1bMV1dKTt2YXIgcz1Ocihh
KSxsPU5yKGMpLGY9bFswXT09PXNbMF0saD1sW2wubGVuZ3RoLTFdPT09c1tzLmxlbmd0aC0xXSxn
PVtdO2Zvcih0PXMubGVuZ3RoLTE7dD49MDstLXQpZy5wdXNoKG5bYVtzW3RdXVsyXV0pO2Zvcih0
PStmO3Q8bC5sZW5ndGgtaDsrK3QpZy5wdXNoKG5bYVtsW3RdXVsyXV0pO3JldHVybiBnfXZhciBl
PUFyLHI9Q3I7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/dChuKToodC54PWZ1bmN0aW9uKG4pe3Jl
dHVybiBhcmd1bWVudHMubGVuZ3RoPyhlPW4sdCk6ZX0sdC55PWZ1bmN0aW9uKG4pe3JldHVybiBh
cmd1bWVudHMubGVuZ3RoPyhyPW4sdCk6cn0sdCl9LEdvLmdlb20ucG9seWdvbj1mdW5jdGlvbihu
KXtyZXR1cm4gZGEobixCYyksbn07dmFyIEJjPUdvLmdlb20ucG9seWdvbi5wcm90b3R5cGU9W107
QmMuYXJlYT1mdW5jdGlvbigpe2Zvcih2YXIgbix0PS0xLGU9dGhpcy5sZW5ndGgscj10aGlzW2Ut
MV0sdT0wOysrdDxlOyluPXIscj10aGlzW3RdLHUrPW5bMV0qclswXS1uWzBdKnJbMV07cmV0dXJu
LjUqdX0sQmMuY2VudHJvaWQ9ZnVuY3Rpb24obil7dmFyIHQsZSxyPS0xLHU9dGhpcy5sZW5ndGgs
aT0wLG89MCxhPXRoaXNbdS0xXTtmb3IoYXJndW1lbnRzLmxlbmd0aHx8KG49LTEvKDYqdGhpcy5h
cmVhKCkpKTsrK3I8dTspdD1hLGE9dGhpc1tyXSxlPXRbMF0qYVsxXS1hWzBdKnRbMV0saSs9KHRb
MF0rYVswXSkqZSxvKz0odFsxXSthWzFdKSplO3JldHVybltpKm4sbypuXX0sQmMuY2xpcD1mdW5j
dGlvbihuKXtmb3IodmFyIHQsZSxyLHUsaSxvLGE9enIobiksYz0tMSxzPXRoaXMubGVuZ3RoLXpy
KHRoaXMpLGw9dGhpc1tzLTFdOysrYzxzOyl7Zm9yKHQ9bi5zbGljZSgpLG4ubGVuZ3RoPTAsdT10
aGlzW2NdLGk9dFsocj10Lmxlbmd0aC1hKS0xXSxlPS0xOysrZTxyOylvPXRbZV0sVHIobyxsLHUp
PyhUcihpLGwsdSl8fG4ucHVzaChxcihpLG8sbCx1KSksbi5wdXNoKG8pKTpUcihpLGwsdSkmJm4u
cHVzaChxcihpLG8sbCx1KSksaT1vO2EmJm4ucHVzaChuWzBdKSxsPXV9cmV0dXJuIG59O3ZhciBK
YyxXYyxHYyxLYyxRYyxucz1bXSx0cz1bXTtPci5wcm90b3R5cGUucHJlcGFyZT1mdW5jdGlvbigp
e2Zvcih2YXIgbix0PXRoaXMuZWRnZXMsZT10Lmxlbmd0aDtlLS07KW49dFtlXS5lZGdlLG4uYiYm
bi5hfHx0LnNwbGljZShlLDEpO3JldHVybiB0LnNvcnQoWXIpLHQubGVuZ3RofSxRci5wcm90b3R5
cGU9e3N0YXJ0OmZ1bmN0aW9uKCl7cmV0dXJuIHRoaXMuZWRnZS5sPT09dGhpcy5zaXRlP3RoaXMu
ZWRnZS5hOnRoaXMuZWRnZS5ifSxlbmQ6ZnVuY3Rpb24oKXtyZXR1cm4gdGhpcy5lZGdlLmw9PT10
aGlzLnNpdGU/dGhpcy5lZGdlLmI6dGhpcy5lZGdlLmF9fSxudS5wcm90b3R5cGU9e2luc2VydDpm
dW5jdGlvbihuLHQpe3ZhciBlLHIsdTtpZihuKXtpZih0LlA9bix0Lk49bi5OLG4uTiYmKG4uTi5Q
PXQpLG4uTj10LG4uUil7Zm9yKG49bi5SO24uTDspbj1uLkw7bi5MPXR9ZWxzZSBuLlI9dDtlPW59
ZWxzZSB0aGlzLl8/KG49dXUodGhpcy5fKSx0LlA9bnVsbCx0Lk49bixuLlA9bi5MPXQsZT1uKToo
dC5QPXQuTj1udWxsLHRoaXMuXz10LGU9bnVsbCk7Zm9yKHQuTD10LlI9bnVsbCx0LlU9ZSx0LkM9
ITAsbj10O2UmJmUuQzspcj1lLlUsZT09PXIuTD8odT1yLlIsdSYmdS5DPyhlLkM9dS5DPSExLHIu
Qz0hMCxuPXIpOihuPT09ZS5SJiYoZXUodGhpcyxlKSxuPWUsZT1uLlUpLGUuQz0hMSxyLkM9ITAs
cnUodGhpcyxyKSkpOih1PXIuTCx1JiZ1LkM/KGUuQz11LkM9ITEsci5DPSEwLG49cik6KG49PT1l
LkwmJihydSh0aGlzLGUpLG49ZSxlPW4uVSksZS5DPSExLHIuQz0hMCxldSh0aGlzLHIpKSksZT1u
LlU7dGhpcy5fLkM9ITF9LHJlbW92ZTpmdW5jdGlvbihuKXtuLk4mJihuLk4uUD1uLlApLG4uUCYm
KG4uUC5OPW4uTiksbi5OPW4uUD1udWxsO3ZhciB0LGUscix1PW4uVSxpPW4uTCxvPW4uUjtpZihl
PWk/bz91dShvKTppOm8sdT91Lkw9PT1uP3UuTD1lOnUuUj1lOnRoaXMuXz1lLGkmJm8/KHI9ZS5D
LGUuQz1uLkMsZS5MPWksaS5VPWUsZSE9PW8/KHU9ZS5VLGUuVT1uLlUsbj1lLlIsdS5MPW4sZS5S
PW8sby5VPWUpOihlLlU9dSx1PWUsbj1lLlIpKToocj1uLkMsbj1lKSxuJiYobi5VPXUpLCFyKXtp
ZihuJiZuLkMpcmV0dXJuIG4uQz0hMSx2b2lkIDA7ZG97aWYobj09PXRoaXMuXylicmVhaztpZihu
PT09dS5MKXtpZih0PXUuUix0LkMmJih0LkM9ITEsdS5DPSEwLGV1KHRoaXMsdSksdD11LlIpLHQu
TCYmdC5MLkN8fHQuUiYmdC5SLkMpe3QuUiYmdC5SLkN8fCh0LkwuQz0hMSx0LkM9ITAscnUodGhp
cyx0KSx0PXUuUiksdC5DPXUuQyx1LkM9dC5SLkM9ITEsZXUodGhpcyx1KSxuPXRoaXMuXzticmVh
a319ZWxzZSBpZih0PXUuTCx0LkMmJih0LkM9ITEsdS5DPSEwLHJ1KHRoaXMsdSksdD11LkwpLHQu
TCYmdC5MLkN8fHQuUiYmdC5SLkMpe3QuTCYmdC5MLkN8fCh0LlIuQz0hMSx0LkM9ITAsZXUodGhp
cyx0KSx0PXUuTCksdC5DPXUuQyx1LkM9dC5MLkM9ITEscnUodGhpcyx1KSxuPXRoaXMuXzticmVh
a310LkM9ITAsbj11LHU9dS5VfXdoaWxlKCFuLkMpO24mJihuLkM9ITEpfX19LEdvLmdlb20udm9y
b25vaT1mdW5jdGlvbihuKXtmdW5jdGlvbiB0KG4pe3ZhciB0PW5ldyBBcnJheShuLmxlbmd0aCks
cj1hWzBdWzBdLHU9YVswXVsxXSxpPWFbMV1bMF0sbz1hWzFdWzFdO3JldHVybiBpdShlKG4pLGEp
LmNlbGxzLmZvckVhY2goZnVuY3Rpb24oZSxhKXt2YXIgYz1lLmVkZ2VzLHM9ZS5zaXRlLGw9dFth
XT1jLmxlbmd0aD9jLm1hcChmdW5jdGlvbihuKXt2YXIgdD1uLnN0YXJ0KCk7cmV0dXJuW3QueCx0
LnldfSk6cy54Pj1yJiZzLng8PWkmJnMueT49dSYmcy55PD1vP1tbcixvXSxbaSxvXSxbaSx1XSxb
cix1XV06W107bC5wb2ludD1uW2FdfSksdH1mdW5jdGlvbiBlKG4pe3JldHVybiBuLm1hcChmdW5j
dGlvbihuLHQpe3JldHVybnt4Ok1hdGgucm91bmQoaShuLHQpL1RhKSpUYSx5Ok1hdGgucm91bmQo
byhuLHQpL1RhKSpUYSxpOnR9fSl9dmFyIHI9QXIsdT1DcixpPXIsbz11LGE9ZXM7cmV0dXJuIG4/
dChuKToodC5saW5rcz1mdW5jdGlvbihuKXtyZXR1cm4gaXUoZShuKSkuZWRnZXMuZmlsdGVyKGZ1
bmN0aW9uKG4pe3JldHVybiBuLmwmJm4ucn0pLm1hcChmdW5jdGlvbih0KXtyZXR1cm57c291cmNl
Om5bdC5sLmldLHRhcmdldDpuW3Quci5pXX19KX0sdC50cmlhbmdsZXM9ZnVuY3Rpb24obil7dmFy
IHQ9W107cmV0dXJuIGl1KGUobikpLmNlbGxzLmZvckVhY2goZnVuY3Rpb24oZSxyKXtmb3IodmFy
IHUsaSxvPWUuc2l0ZSxhPWUuZWRnZXMuc29ydChZciksYz0tMSxzPWEubGVuZ3RoLGw9YVtzLTFd
LmVkZ2UsZj1sLmw9PT1vP2wucjpsLmw7KytjPHM7KXU9bCxpPWYsbD1hW2NdLmVkZ2UsZj1sLmw9
PT1vP2wucjpsLmwscjxpLmkmJnI8Zi5pJiZhdShvLGksZik8MCYmdC5wdXNoKFtuW3JdLG5baS5p
XSxuW2YuaV1dKX0pLHR9LHQueD1mdW5jdGlvbihuKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8o
aT1FdChyPW4pLHQpOnJ9LHQueT1mdW5jdGlvbihuKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8o
bz1FdCh1PW4pLHQpOnV9LHQuY2xpcEV4dGVudD1mdW5jdGlvbihuKXtyZXR1cm4gYXJndW1lbnRz
Lmxlbmd0aD8oYT1udWxsPT1uP2VzOm4sdCk6YT09PWVzP251bGw6YX0sdC5zaXplPWZ1bmN0aW9u
KG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoP3QuY2xpcEV4dGVudChuJiZbWzAsMF0sbl0pOmE9
PT1lcz9udWxsOmEmJmFbMV19LHQpfTt2YXIgZXM9W1stMWU2LC0xZTZdLFsxZTYsMWU2XV07R28u
Z2VvbS5kZWxhdW5heT1mdW5jdGlvbihuKXtyZXR1cm4gR28uZ2VvbS52b3Jvbm9pKCkudHJpYW5n
bGVzKG4pfSxHby5nZW9tLnF1YWR0cmVlPWZ1bmN0aW9uKG4sdCxlLHIsdSl7ZnVuY3Rpb24gaShu
KXtmdW5jdGlvbiBpKG4sdCxlLHIsdSxpLG8sYSl7aWYoIWlzTmFOKGUpJiYhaXNOYU4ocikpaWYo
bi5sZWFmKXt2YXIgYz1uLngsbD1uLnk7aWYobnVsbCE9YylpZihmYShjLWUpK2ZhKGwtcik8LjAx
KXMobix0LGUscix1LGksbyxhKTtlbHNle3ZhciBmPW4ucG9pbnQ7bi54PW4ueT1uLnBvaW50PW51
bGwscyhuLGYsYyxsLHUsaSxvLGEpLHMobix0LGUscix1LGksbyxhKX1lbHNlIG4ueD1lLG4ueT1y
LG4ucG9pbnQ9dH1lbHNlIHMobix0LGUscix1LGksbyxhKX1mdW5jdGlvbiBzKG4sdCxlLHIsdSxv
LGEsYyl7dmFyIHM9LjUqKHUrYSksbD0uNSoobytjKSxmPWU+PXMsaD1yPj1sLGc9KGg8PDEpK2Y7
bi5sZWFmPSExLG49bi5ub2Rlc1tnXXx8KG4ubm9kZXNbZ109bHUoKSksZj91PXM6YT1zLGg/bz1s
OmM9bCxpKG4sdCxlLHIsdSxvLGEsYyl9dmFyIGwsZixoLGcscCx2LGQsbSx5LHg9RXQoYSksTT1F
dChjKTtpZihudWxsIT10KXY9dCxkPWUsbT1yLHk9dTtlbHNlIGlmKG09eT0tKHY9ZD0xLzApLGY9
W10saD1bXSxwPW4ubGVuZ3RoLG8pZm9yKGc9MDtwPmc7KytnKWw9bltnXSxsLng8diYmKHY9bC54
KSxsLnk8ZCYmKGQ9bC55KSxsLng+bSYmKG09bC54KSxsLnk+eSYmKHk9bC55KSxmLnB1c2gobC54
KSxoLnB1c2gobC55KTtlbHNlIGZvcihnPTA7cD5nOysrZyl7dmFyIF89K3gobD1uW2ddLGcpLGI9
K00obCxnKTt2Pl8mJih2PV8pLGQ+YiYmKGQ9YiksXz5tJiYobT1fKSxiPnkmJih5PWIpLGYucHVz
aChfKSxoLnB1c2goYil9dmFyIHc9bS12LFM9eS1kO3c+Uz95PWQrdzptPXYrUzt2YXIgaz1sdSgp
O2lmKGsuYWRkPWZ1bmN0aW9uKG4pe2koayxuLCt4KG4sKytnKSwrTShuLGcpLHYsZCxtLHkpfSxr
LnZpc2l0PWZ1bmN0aW9uKG4pe2Z1KG4sayx2LGQsbSx5KX0sZz0tMSxudWxsPT10KXtmb3IoOysr
ZzxwOylpKGssbltnXSxmW2ddLGhbZ10sdixkLG0seSk7LS1nfWVsc2Ugbi5mb3JFYWNoKGsuYWRk
KTtyZXR1cm4gZj1oPW49bD1udWxsLGt9dmFyIG8sYT1BcixjPUNyO3JldHVybihvPWFyZ3VtZW50
cy5sZW5ndGgpPyhhPWN1LGM9c3UsMz09PW8mJih1PWUscj10LGU9dD0wKSxpKG4pKTooaS54PWZ1
bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhhPW4saSk6YX0saS55PWZ1bmN0aW9u
KG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhjPW4saSk6Y30saS5leHRlbnQ9ZnVuY3Rpb24o
bil7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KG51bGw9PW4/dD1lPXI9dT1udWxsOih0PStuWzBd
WzBdLGU9K25bMF1bMV0scj0rblsxXVswXSx1PStuWzFdWzFdKSxpKTpudWxsPT10P251bGw6W1t0
LGVdLFtyLHVdXX0saS5zaXplPWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhu
dWxsPT1uP3Q9ZT1yPXU9bnVsbDoodD1lPTAscj0rblswXSx1PStuWzFdKSxpKTpudWxsPT10P251
bGw6W3ItdCx1LWVdfSxpKX0sR28uaW50ZXJwb2xhdGVSZ2I9aHUsR28uaW50ZXJwb2xhdGVPYmpl
Y3Q9Z3UsR28uaW50ZXJwb2xhdGVOdW1iZXI9cHUsR28uaW50ZXJwb2xhdGVTdHJpbmc9dnU7dmFy
IHJzPS9bLStdPyg/OlxkK1wuP1xkKnxcLj9cZCspKD86W2VFXVstK10/XGQrKT8vZyx1cz1uZXcg
UmVnRXhwKHJzLnNvdXJjZSwiZyIpO0dvLmludGVycG9sYXRlPWR1LEdvLmludGVycG9sYXRvcnM9
W2Z1bmN0aW9uKG4sdCl7dmFyIGU9dHlwZW9mIHQ7cmV0dXJuKCJzdHJpbmciPT09ZT9KYS5oYXMo
dCl8fC9eKCN8cmdiXCh8aHNsXCgpLy50ZXN0KHQpP2h1OnZ1OnQgaW5zdGFuY2VvZiBldD9odTpB
cnJheS5pc0FycmF5KHQpP211OiJvYmplY3QiPT09ZSYmaXNOYU4odCk/Z3U6cHUpKG4sdCl9XSxH
by5pbnRlcnBvbGF0ZUFycmF5PW11O3ZhciBpcz1mdW5jdGlvbigpe3JldHVybiBBdH0sb3M9R28u
bWFwKHtsaW5lYXI6aXMscG9seTpTdSxxdWFkOmZ1bmN0aW9uKCl7cmV0dXJuIF91fSxjdWJpYzpm
dW5jdGlvbigpe3JldHVybiBidX0sc2luOmZ1bmN0aW9uKCl7cmV0dXJuIGt1fSxleHA6ZnVuY3Rp
b24oKXtyZXR1cm4gRXV9LGNpcmNsZTpmdW5jdGlvbigpe3JldHVybiBBdX0sZWxhc3RpYzpDdSxi
YWNrOk51LGJvdW5jZTpmdW5jdGlvbigpe3JldHVybiBMdX19KSxhcz1Hby5tYXAoeyJpbiI6QXQs
b3V0Onh1LCJpbi1vdXQiOk11LCJvdXQtaW4iOmZ1bmN0aW9uKG4pe3JldHVybiBNdSh4dShuKSl9
fSk7R28uZWFzZT1mdW5jdGlvbihuKXt2YXIgdD1uLmluZGV4T2YoIi0iKSxlPXQ+PTA/bi5zdWJz
dHJpbmcoMCx0KTpuLHI9dD49MD9uLnN1YnN0cmluZyh0KzEpOiJpbiI7cmV0dXJuIGU9b3MuZ2V0
KGUpfHxpcyxyPWFzLmdldChyKXx8QXQseXUocihlLmFwcGx5KG51bGwsS28uY2FsbChhcmd1bWVu
dHMsMSkpKSl9LEdvLmludGVycG9sYXRlSGNsPVR1LEdvLmludGVycG9sYXRlSHNsPXF1LEdvLmlu
dGVycG9sYXRlTGFiPXp1LEdvLmludGVycG9sYXRlUm91bmQ9UnUsR28udHJhbnNmb3JtPWZ1bmN0
aW9uKG4pe3ZhciB0PW5hLmNyZWF0ZUVsZW1lbnROUyhHby5ucy5wcmVmaXguc3ZnLCJnIik7cmV0
dXJuKEdvLnRyYW5zZm9ybT1mdW5jdGlvbihuKXtpZihudWxsIT1uKXt0LnNldEF0dHJpYnV0ZSgi
dHJhbnNmb3JtIixuKTt2YXIgZT10LnRyYW5zZm9ybS5iYXNlVmFsLmNvbnNvbGlkYXRlKCl9cmV0
dXJuIG5ldyBEdShlP2UubWF0cml4OmNzKX0pKG4pfSxEdS5wcm90b3R5cGUudG9TdHJpbmc9ZnVu
Y3Rpb24oKXtyZXR1cm4idHJhbnNsYXRlKCIrdGhpcy50cmFuc2xhdGUrIilyb3RhdGUoIit0aGlz
LnJvdGF0ZSsiKXNrZXdYKCIrdGhpcy5za2V3KyIpc2NhbGUoIit0aGlzLnNjYWxlKyIpIn07dmFy
IGNzPXthOjEsYjowLGM6MCxkOjEsZTowLGY6MH07R28uaW50ZXJwb2xhdGVUcmFuc2Zvcm09SHUs
R28ubGF5b3V0PXt9LEdvLmxheW91dC5idW5kbGU9ZnVuY3Rpb24oKXtyZXR1cm4gZnVuY3Rpb24o
bil7Zm9yKHZhciB0PVtdLGU9LTEscj1uLmxlbmd0aDsrK2U8cjspdC5wdXNoKEl1KG5bZV0pKTty
ZXR1cm4gdH19LEdvLmxheW91dC5jaG9yZD1mdW5jdGlvbigpe2Z1bmN0aW9uIG4oKXt2YXIgbixz
LGYsaCxnLHA9e30sdj1bXSxkPUdvLnJhbmdlKGkpLG09W107Zm9yKGU9W10scj1bXSxuPTAsaD0t
MTsrK2g8aTspe2ZvcihzPTAsZz0tMTsrK2c8aTspcys9dVtoXVtnXTt2LnB1c2gocyksbS5wdXNo
KEdvLnJhbmdlKGkpKSxuKz1zfWZvcihvJiZkLnNvcnQoZnVuY3Rpb24obix0KXtyZXR1cm4gbyh2
W25dLHZbdF0pfSksYSYmbS5mb3JFYWNoKGZ1bmN0aW9uKG4sdCl7bi5zb3J0KGZ1bmN0aW9uKG4s
ZSl7cmV0dXJuIGEodVt0XVtuXSx1W3RdW2VdKX0pfSksbj0oTmEtbCppKS9uLHM9MCxoPS0xOysr
aDxpOyl7Zm9yKGY9cyxnPS0xOysrZzxpOyl7dmFyIHk9ZFtoXSx4PW1beV1bZ10sTT11W3ldW3hd
LF89cyxiPXMrPU0qbjtwW3krIi0iK3hdPXtpbmRleDp5LHN1YmluZGV4Ongsc3RhcnRBbmdsZTpf
LGVuZEFuZ2xlOmIsdmFsdWU6TX19clt5XT17aW5kZXg6eSxzdGFydEFuZ2xlOmYsZW5kQW5nbGU6
cyx2YWx1ZToocy1mKS9ufSxzKz1sfWZvcihoPS0xOysraDxpOylmb3IoZz1oLTE7KytnPGk7KXt2
YXIgdz1wW2grIi0iK2ddLFM9cFtnKyItIitoXTsody52YWx1ZXx8Uy52YWx1ZSkmJmUucHVzaCh3
LnZhbHVlPFMudmFsdWU/e3NvdXJjZTpTLHRhcmdldDp3fTp7c291cmNlOncsdGFyZ2V0OlN9KX1j
JiZ0KCl9ZnVuY3Rpb24gdCgpe2Uuc29ydChmdW5jdGlvbihuLHQpe3JldHVybiBjKChuLnNvdXJj
ZS52YWx1ZStuLnRhcmdldC52YWx1ZSkvMiwodC5zb3VyY2UudmFsdWUrdC50YXJnZXQudmFsdWUp
LzIpfSl9dmFyIGUscix1LGksbyxhLGMscz17fSxsPTA7cmV0dXJuIHMubWF0cml4PWZ1bmN0aW9u
KG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhpPSh1PW4pJiZ1Lmxlbmd0aCxlPXI9bnVsbCxz
KTp1fSxzLnBhZGRpbmc9ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KGw9bixl
PXI9bnVsbCxzKTpsfSxzLnNvcnRHcm91cHM9ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5s
ZW5ndGg/KG89bixlPXI9bnVsbCxzKTpvfSxzLnNvcnRTdWJncm91cHM9ZnVuY3Rpb24obil7cmV0
dXJuIGFyZ3VtZW50cy5sZW5ndGg/KGE9bixlPW51bGwscyk6YX0scy5zb3J0Q2hvcmRzPWZ1bmN0
aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhjPW4sZSYmdCgpLHMpOmN9LHMuY2hvcmRz
PWZ1bmN0aW9uKCl7cmV0dXJuIGV8fG4oKSxlfSxzLmdyb3Vwcz1mdW5jdGlvbigpe3JldHVybiBy
fHxuKCkscn0sc30sR28ubGF5b3V0LmZvcmNlPWZ1bmN0aW9uKCl7ZnVuY3Rpb24gbihuKXtyZXR1
cm4gZnVuY3Rpb24odCxlLHIsdSl7aWYodC5wb2ludCE9PW4pe3ZhciBpPXQuY3gtbi54LG89dC5j
eS1uLnksYT11LWUsYz1pKmkrbypvO2lmKGM+YSphL2Qpe2lmKHA+Yyl7dmFyIHM9dC5jaGFyZ2Uv
YztuLnB4LT1pKnMsbi5weS09bypzfXJldHVybiEwfWlmKHQucG9pbnQmJmMmJnA+Yyl7dmFyIHM9
dC5wb2ludENoYXJnZS9jO24ucHgtPWkqcyxuLnB5LT1vKnN9fXJldHVybiF0LmNoYXJnZX19ZnVu
Y3Rpb24gdChuKXtuLnB4PUdvLmV2ZW50Lngsbi5weT1Hby5ldmVudC55LGEucmVzdW1lKCl9dmFy
IGUscix1LGksbyxhPXt9LGM9R28uZGlzcGF0Y2goInN0YXJ0IiwidGljayIsImVuZCIpLHM9WzEs
MV0sbD0uOSxmPXNzLGg9bHMsZz0tMzAscD1mcyx2PS4xLGQ9LjY0LG09W10seT1bXTtyZXR1cm4g
YS50aWNrPWZ1bmN0aW9uKCl7aWYoKHIqPS45OSk8LjAwNSlyZXR1cm4gYy5lbmQoe3R5cGU6ImVu
ZCIsYWxwaGE6cj0wfSksITA7dmFyIHQsZSxhLGYsaCxwLGQseCxNLF89bS5sZW5ndGgsYj15Lmxl
bmd0aDtmb3IoZT0wO2I+ZTsrK2UpYT15W2VdLGY9YS5zb3VyY2UsaD1hLnRhcmdldCx4PWgueC1m
LngsTT1oLnktZi55LChwPXgqeCtNKk0pJiYocD1yKmlbZV0qKChwPU1hdGguc3FydChwKSktdVtl
XSkvcCx4Kj1wLE0qPXAsaC54LT14KihkPWYud2VpZ2h0LyhoLndlaWdodCtmLndlaWdodCkpLGgu
eS09TSpkLGYueCs9eCooZD0xLWQpLGYueSs9TSpkKTtpZigoZD1yKnYpJiYoeD1zWzBdLzIsTT1z
WzFdLzIsZT0tMSxkKSlmb3IoOysrZTxfOylhPW1bZV0sYS54Kz0oeC1hLngpKmQsYS55Kz0oTS1h
LnkpKmQ7aWYoZylmb3IoSnUodD1Hby5nZW9tLnF1YWR0cmVlKG0pLHIsbyksZT0tMTsrK2U8Xzsp
KGE9bVtlXSkuZml4ZWR8fHQudmlzaXQobihhKSk7Zm9yKGU9LTE7KytlPF87KWE9bVtlXSxhLmZp
eGVkPyhhLng9YS5weCxhLnk9YS5weSk6KGEueC09KGEucHgtKGEucHg9YS54KSkqbCxhLnktPShh
LnB5LShhLnB5PWEueSkpKmwpO2MudGljayh7dHlwZToidGljayIsYWxwaGE6cn0pfSxhLm5vZGVz
PWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhtPW4sYSk6bX0sYS5saW5rcz1m
dW5jdGlvbihuKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oeT1uLGEpOnl9LGEuc2l6ZT1mdW5j
dGlvbihuKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8ocz1uLGEpOnN9LGEubGlua0Rpc3RhbmNl
PWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhmPSJmdW5jdGlvbiI9PXR5cGVv
ZiBuP246K24sYSk6Zn0sYS5kaXN0YW5jZT1hLmxpbmtEaXN0YW5jZSxhLmxpbmtTdHJlbmd0aD1m
dW5jdGlvbihuKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oaD0iZnVuY3Rpb24iPT10eXBlb2Yg
bj9uOituLGEpOmh9LGEuZnJpY3Rpb249ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5sZW5n
dGg/KGw9K24sYSk6bH0sYS5jaGFyZ2U9ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5sZW5n
dGg/KGc9ImZ1bmN0aW9uIj09dHlwZW9mIG4/bjorbixhKTpnfSxhLmNoYXJnZURpc3RhbmNlPWZ1
bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhwPW4qbixhKTpNYXRoLnNxcnQocCl9
LGEuZ3Jhdml0eT1mdW5jdGlvbihuKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8odj0rbixhKTp2
fSxhLnRoZXRhPWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhkPW4qbixhKTpN
YXRoLnNxcnQoZCl9LGEuYWxwaGE9ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/
KG49K24scj9yPW4+MD9uOjA6bj4wJiYoYy5zdGFydCh7dHlwZToic3RhcnQiLGFscGhhOnI9bn0p
LEdvLnRpbWVyKGEudGljaykpLGEpOnJ9LGEuc3RhcnQ9ZnVuY3Rpb24oKXtmdW5jdGlvbiBuKG4s
cil7aWYoIWUpe2ZvcihlPW5ldyBBcnJheShjKSxhPTA7Yz5hOysrYSllW2FdPVtdO2ZvcihhPTA7
cz5hOysrYSl7dmFyIHU9eVthXTtlW3Uuc291cmNlLmluZGV4XS5wdXNoKHUudGFyZ2V0KSxlW3Uu
dGFyZ2V0LmluZGV4XS5wdXNoKHUuc291cmNlKX19Zm9yKHZhciBpLG89ZVt0XSxhPS0xLHM9by5s
ZW5ndGg7KythPHM7KWlmKCFpc05hTihpPW9bYV1bbl0pKXJldHVybiBpO3JldHVybiBNYXRoLnJh
bmRvbSgpKnJ9dmFyIHQsZSxyLGM9bS5sZW5ndGgsbD15Lmxlbmd0aCxwPXNbMF0sdj1zWzFdO2Zv
cih0PTA7Yz50OysrdCkocj1tW3RdKS5pbmRleD10LHIud2VpZ2h0PTA7Zm9yKHQ9MDtsPnQ7Kyt0
KXI9eVt0XSwibnVtYmVyIj09dHlwZW9mIHIuc291cmNlJiYoci5zb3VyY2U9bVtyLnNvdXJjZV0p
LCJudW1iZXIiPT10eXBlb2Ygci50YXJnZXQmJihyLnRhcmdldD1tW3IudGFyZ2V0XSksKytyLnNv
dXJjZS53ZWlnaHQsKytyLnRhcmdldC53ZWlnaHQ7Zm9yKHQ9MDtjPnQ7Kyt0KXI9bVt0XSxpc05h
TihyLngpJiYoci54PW4oIngiLHApKSxpc05hTihyLnkpJiYoci55PW4oInkiLHYpKSxpc05hTihy
LnB4KSYmKHIucHg9ci54KSxpc05hTihyLnB5KSYmKHIucHk9ci55KTtpZih1PVtdLCJmdW5jdGlv
biI9PXR5cGVvZiBmKWZvcih0PTA7bD50OysrdCl1W3RdPStmLmNhbGwodGhpcyx5W3RdLHQpO2Vs
c2UgZm9yKHQ9MDtsPnQ7Kyt0KXVbdF09ZjtpZihpPVtdLCJmdW5jdGlvbiI9PXR5cGVvZiBoKWZv
cih0PTA7bD50OysrdClpW3RdPStoLmNhbGwodGhpcyx5W3RdLHQpO2Vsc2UgZm9yKHQ9MDtsPnQ7
Kyt0KWlbdF09aDtpZihvPVtdLCJmdW5jdGlvbiI9PXR5cGVvZiBnKWZvcih0PTA7Yz50OysrdClv
W3RdPStnLmNhbGwodGhpcyxtW3RdLHQpO2Vsc2UgZm9yKHQ9MDtjPnQ7Kyt0KW9bdF09ZztyZXR1
cm4gYS5yZXN1bWUoKX0sYS5yZXN1bWU9ZnVuY3Rpb24oKXtyZXR1cm4gYS5hbHBoYSguMSl9LGEu
c3RvcD1mdW5jdGlvbigpe3JldHVybiBhLmFscGhhKDApfSxhLmRyYWc9ZnVuY3Rpb24oKXtyZXR1
cm4gZXx8KGU9R28uYmVoYXZpb3IuZHJhZygpLm9yaWdpbihBdCkub24oImRyYWdzdGFydC5mb3Jj
ZSIsVnUpLm9uKCJkcmFnLmZvcmNlIix0KS5vbigiZHJhZ2VuZC5mb3JjZSIsJHUpKSxhcmd1bWVu
dHMubGVuZ3RoPyh0aGlzLm9uKCJtb3VzZW92ZXIuZm9yY2UiLFh1KS5vbigibW91c2VvdXQuZm9y
Y2UiLEJ1KS5jYWxsKGUpLHZvaWQgMCk6ZX0sR28ucmViaW5kKGEsYywib24iKX07dmFyIHNzPTIw
LGxzPTEsZnM9MS8wO0dvLmxheW91dC5oaWVyYXJjaHk9ZnVuY3Rpb24oKXtmdW5jdGlvbiBuKHQs
byxhKXt2YXIgYz11LmNhbGwoZSx0LG8pO2lmKHQuZGVwdGg9byxhLnB1c2godCksYyYmKHM9Yy5s
ZW5ndGgpKXtmb3IodmFyIHMsbCxmPS0xLGg9dC5jaGlsZHJlbj1uZXcgQXJyYXkocyksZz0wLHA9
bysxOysrZjxzOylsPWhbZl09bihjW2ZdLHAsYSksbC5wYXJlbnQ9dCxnKz1sLnZhbHVlO3ImJmgu
c29ydChyKSxpJiYodC52YWx1ZT1nKX1lbHNlIGRlbGV0ZSB0LmNoaWxkcmVuLGkmJih0LnZhbHVl
PStpLmNhbGwoZSx0LG8pfHwwKTtyZXR1cm4gdH1mdW5jdGlvbiB0KG4scil7dmFyIHU9bi5jaGls
ZHJlbixvPTA7aWYodSYmKGE9dS5sZW5ndGgpKWZvcih2YXIgYSxjPS0xLHM9cisxOysrYzxhOylv
Kz10KHVbY10scyk7ZWxzZSBpJiYobz0raS5jYWxsKGUsbixyKXx8MCk7cmV0dXJuIGkmJihuLnZh
bHVlPW8pLG99ZnVuY3Rpb24gZSh0KXt2YXIgZT1bXTtyZXR1cm4gbih0LDAsZSksZX12YXIgcj1R
dSx1PUd1LGk9S3U7cmV0dXJuIGUuc29ydD1mdW5jdGlvbihuKXtyZXR1cm4gYXJndW1lbnRzLmxl
bmd0aD8ocj1uLGUpOnJ9LGUuY2hpbGRyZW49ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5s
ZW5ndGg/KHU9bixlKTp1fSxlLnZhbHVlPWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVu
Z3RoPyhpPW4sZSk6aX0sZS5yZXZhbHVlPWZ1bmN0aW9uKG4pe3JldHVybiB0KG4sMCksbn0sZX0s
R28ubGF5b3V0LnBhcnRpdGlvbj1mdW5jdGlvbigpe2Z1bmN0aW9uIG4odCxlLHIsdSl7dmFyIGk9
dC5jaGlsZHJlbjtpZih0Lng9ZSx0Lnk9dC5kZXB0aCp1LHQuZHg9cix0LmR5PXUsaSYmKG89aS5s
ZW5ndGgpKXt2YXIgbyxhLGMscz0tMTtmb3Iocj10LnZhbHVlP3IvdC52YWx1ZTowOysrczxvOylu
KGE9aVtzXSxlLGM9YS52YWx1ZSpyLHUpLGUrPWN9fWZ1bmN0aW9uIHQobil7dmFyIGU9bi5jaGls
ZHJlbixyPTA7aWYoZSYmKHU9ZS5sZW5ndGgpKWZvcih2YXIgdSxpPS0xOysraTx1OylyPU1hdGgu
bWF4KHIsdChlW2ldKSk7cmV0dXJuIDErcn1mdW5jdGlvbiBlKGUsaSl7dmFyIG89ci5jYWxsKHRo
aXMsZSxpKTtyZXR1cm4gbihvWzBdLDAsdVswXSx1WzFdL3Qob1swXSkpLG99dmFyIHI9R28ubGF5
b3V0LmhpZXJhcmNoeSgpLHU9WzEsMV07cmV0dXJuIGUuc2l6ZT1mdW5jdGlvbihuKXtyZXR1cm4g
YXJndW1lbnRzLmxlbmd0aD8odT1uLGUpOnV9LFd1KGUscil9LEdvLmxheW91dC5waWU9ZnVuY3Rp
b24oKXtmdW5jdGlvbiBuKGkpe3ZhciBvPWkubWFwKGZ1bmN0aW9uKGUscil7cmV0dXJuK3QuY2Fs
bChuLGUscil9KSxhPSsoImZ1bmN0aW9uIj09dHlwZW9mIHI/ci5hcHBseSh0aGlzLGFyZ3VtZW50
cyk6ciksYz0oKCJmdW5jdGlvbiI9PXR5cGVvZiB1P3UuYXBwbHkodGhpcyxhcmd1bWVudHMpOnUp
LWEpL0dvLnN1bShvKSxzPUdvLnJhbmdlKGkubGVuZ3RoKTtudWxsIT1lJiZzLnNvcnQoZT09PWhz
P2Z1bmN0aW9uKG4sdCl7cmV0dXJuIG9bdF0tb1tuXX06ZnVuY3Rpb24obix0KXtyZXR1cm4gZShp
W25dLGlbdF0pfSk7dmFyIGw9W107cmV0dXJuIHMuZm9yRWFjaChmdW5jdGlvbihuKXt2YXIgdDts
W25dPXtkYXRhOmlbbl0sdmFsdWU6dD1vW25dLHN0YXJ0QW5nbGU6YSxlbmRBbmdsZTphKz10KmN9
fSksbH12YXIgdD1OdW1iZXIsZT1ocyxyPTAsdT1OYTtyZXR1cm4gbi52YWx1ZT1mdW5jdGlvbihl
KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8odD1lLG4pOnR9LG4uc29ydD1mdW5jdGlvbih0KXty
ZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oZT10LG4pOmV9LG4uc3RhcnRBbmdsZT1mdW5jdGlvbih0
KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8ocj10LG4pOnJ9LG4uZW5kQW5nbGU9ZnVuY3Rpb24o
dCl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KHU9dCxuKTp1fSxufTt2YXIgaHM9e307R28ubGF5
b3V0LnN0YWNrPWZ1bmN0aW9uKCl7ZnVuY3Rpb24gbihhLGMpe3ZhciBzPWEubWFwKGZ1bmN0aW9u
KGUscil7cmV0dXJuIHQuY2FsbChuLGUscil9KSxsPXMubWFwKGZ1bmN0aW9uKHQpe3JldHVybiB0
Lm1hcChmdW5jdGlvbih0LGUpe3JldHVybltpLmNhbGwobix0LGUpLG8uY2FsbChuLHQsZSldfSl9
KSxmPWUuY2FsbChuLGwsYyk7cz1Hby5wZXJtdXRlKHMsZiksbD1Hby5wZXJtdXRlKGwsZik7dmFy
IGgsZyxwLHY9ci5jYWxsKG4sbCxjKSxkPXMubGVuZ3RoLG09c1swXS5sZW5ndGg7Zm9yKGc9MDtt
Pmc7KytnKWZvcih1LmNhbGwobixzWzBdW2ddLHA9dltnXSxsWzBdW2ddWzFdKSxoPTE7ZD5oOysr
aCl1LmNhbGwobixzW2hdW2ddLHArPWxbaC0xXVtnXVsxXSxsW2hdW2ddWzFdKTtyZXR1cm4gYX12
YXIgdD1BdCxlPXVpLHI9aWksdT1yaSxpPXRpLG89ZWk7cmV0dXJuIG4udmFsdWVzPWZ1bmN0aW9u
KGUpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyh0PWUsbik6dH0sbi5vcmRlcj1mdW5jdGlvbih0
KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oZT0iZnVuY3Rpb24iPT10eXBlb2YgdD90OmdzLmdl
dCh0KXx8dWksbik6ZX0sbi5vZmZzZXQ9ZnVuY3Rpb24odCl7cmV0dXJuIGFyZ3VtZW50cy5sZW5n
dGg/KHI9ImZ1bmN0aW9uIj09dHlwZW9mIHQ/dDpwcy5nZXQodCl8fGlpLG4pOnJ9LG4ueD1mdW5j
dGlvbih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oaT10LG4pOml9LG4ueT1mdW5jdGlvbih0
KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8obz10LG4pOm99LG4ub3V0PWZ1bmN0aW9uKHQpe3Jl
dHVybiBhcmd1bWVudHMubGVuZ3RoPyh1PXQsbik6dX0sbn07dmFyIGdzPUdvLm1hcCh7Imluc2lk
ZS1vdXQiOmZ1bmN0aW9uKG4pe3ZhciB0LGUscj1uLmxlbmd0aCx1PW4ubWFwKG9pKSxpPW4ubWFw
KGFpKSxvPUdvLnJhbmdlKHIpLnNvcnQoZnVuY3Rpb24obix0KXtyZXR1cm4gdVtuXS11W3RdfSks
YT0wLGM9MCxzPVtdLGw9W107Zm9yKHQ9MDtyPnQ7Kyt0KWU9b1t0XSxjPmE/KGErPWlbZV0scy5w
dXNoKGUpKTooYys9aVtlXSxsLnB1c2goZSkpO3JldHVybiBsLnJldmVyc2UoKS5jb25jYXQocyl9
LHJldmVyc2U6ZnVuY3Rpb24obil7cmV0dXJuIEdvLnJhbmdlKG4ubGVuZ3RoKS5yZXZlcnNlKCl9
LCJkZWZhdWx0Ijp1aX0pLHBzPUdvLm1hcCh7c2lsaG91ZXR0ZTpmdW5jdGlvbihuKXt2YXIgdCxl
LHIsdT1uLmxlbmd0aCxpPW5bMF0ubGVuZ3RoLG89W10sYT0wLGM9W107Zm9yKGU9MDtpPmU7Kytl
KXtmb3IodD0wLHI9MDt1PnQ7dCsrKXIrPW5bdF1bZV1bMV07cj5hJiYoYT1yKSxvLnB1c2gocil9
Zm9yKGU9MDtpPmU7KytlKWNbZV09KGEtb1tlXSkvMjtyZXR1cm4gY30sd2lnZ2xlOmZ1bmN0aW9u
KG4pe3ZhciB0LGUscix1LGksbyxhLGMscyxsPW4ubGVuZ3RoLGY9blswXSxoPWYubGVuZ3RoLGc9
W107Zm9yKGdbMF09Yz1zPTAsZT0xO2g+ZTsrK2Upe2Zvcih0PTAsdT0wO2w+dDsrK3QpdSs9blt0
XVtlXVsxXTtmb3IodD0wLGk9MCxhPWZbZV1bMF0tZltlLTFdWzBdO2w+dDsrK3Qpe2ZvcihyPTAs
bz0oblt0XVtlXVsxXS1uW3RdW2UtMV1bMV0pLygyKmEpO3Q+cjsrK3Ipbys9KG5bcl1bZV1bMV0t
bltyXVtlLTFdWzFdKS9hO2krPW8qblt0XVtlXVsxXX1nW2VdPWMtPXU/aS91KmE6MCxzPmMmJihz
PWMpfWZvcihlPTA7aD5lOysrZSlnW2VdLT1zO3JldHVybiBnfSxleHBhbmQ6ZnVuY3Rpb24obil7
dmFyIHQsZSxyLHU9bi5sZW5ndGgsaT1uWzBdLmxlbmd0aCxvPTEvdSxhPVtdO2ZvcihlPTA7aT5l
OysrZSl7Zm9yKHQ9MCxyPTA7dT50O3QrKylyKz1uW3RdW2VdWzFdO2lmKHIpZm9yKHQ9MDt1PnQ7
dCsrKW5bdF1bZV1bMV0vPXI7ZWxzZSBmb3IodD0wO3U+dDt0Kyspblt0XVtlXVsxXT1vfWZvcihl
PTA7aT5lOysrZSlhW2VdPTA7cmV0dXJuIGF9LHplcm86aWl9KTtHby5sYXlvdXQuaGlzdG9ncmFt
PWZ1bmN0aW9uKCl7ZnVuY3Rpb24gbihuLGkpe2Zvcih2YXIgbyxhLGM9W10scz1uLm1hcChlLHRo
aXMpLGw9ci5jYWxsKHRoaXMscyxpKSxmPXUuY2FsbCh0aGlzLGwscyxpKSxpPS0xLGg9cy5sZW5n
dGgsZz1mLmxlbmd0aC0xLHA9dD8xOjEvaDsrK2k8Zzspbz1jW2ldPVtdLG8uZHg9ZltpKzFdLShv
Lng9ZltpXSksby55PTA7aWYoZz4wKWZvcihpPS0xOysraTxoOylhPXNbaV0sYT49bFswXSYmYTw9
bFsxXSYmKG89Y1tHby5iaXNlY3QoZixhLDEsZyktMV0sby55Kz1wLG8ucHVzaChuW2ldKSk7cmV0
dXJuIGN9dmFyIHQ9ITAsZT1OdW1iZXIscj1maSx1PXNpO3JldHVybiBuLnZhbHVlPWZ1bmN0aW9u
KHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhlPXQsbik6ZX0sbi5yYW5nZT1mdW5jdGlvbih0
KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8ocj1FdCh0KSxuKTpyfSxuLmJpbnM9ZnVuY3Rpb24o
dCl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KHU9Im51bWJlciI9PXR5cGVvZiB0P2Z1bmN0aW9u
KG4pe3JldHVybiBsaShuLHQpfTpFdCh0KSxuKTp1fSxuLmZyZXF1ZW5jeT1mdW5jdGlvbihlKXty
ZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8odD0hIWUsbik6dH0sbn0sR28ubGF5b3V0LnRyZWU9ZnVu
Y3Rpb24oKXtmdW5jdGlvbiBuKG4saSl7ZnVuY3Rpb24gbyhuLHQpe3ZhciByPW4uY2hpbGRyZW4s
dT1uLl90cmVlO2lmKHImJihpPXIubGVuZ3RoKSl7Zm9yKHZhciBpLGEscyxsPXJbMF0sZj1sLGg9
LTE7KytoPGk7KXM9cltoXSxvKHMsYSksZj1jKHMsYSxmKSxhPXM7TWkobik7dmFyIGc9LjUqKGwu
X3RyZWUucHJlbGltK3MuX3RyZWUucHJlbGltKTt0Pyh1LnByZWxpbT10Ll90cmVlLnByZWxpbStl
KG4sdCksdS5tb2Q9dS5wcmVsaW0tZyk6dS5wcmVsaW09Z31lbHNlIHQmJih1LnByZWxpbT10Ll90
cmVlLnByZWxpbStlKG4sdCkpfWZ1bmN0aW9uIGEobix0KXtuLng9bi5fdHJlZS5wcmVsaW0rdDt2
YXIgZT1uLmNoaWxkcmVuO2lmKGUmJihyPWUubGVuZ3RoKSl7dmFyIHIsdT0tMTtmb3IodCs9bi5f
dHJlZS5tb2Q7Kyt1PHI7KWEoZVt1XSx0KX19ZnVuY3Rpb24gYyhuLHQscil7aWYodCl7Zm9yKHZh
ciB1LGk9bixvPW4sYT10LGM9bi5wYXJlbnQuY2hpbGRyZW5bMF0scz1pLl90cmVlLm1vZCxsPW8u
X3RyZWUubW9kLGY9YS5fdHJlZS5tb2QsaD1jLl90cmVlLm1vZDthPXBpKGEpLGk9Z2koaSksYSYm
aTspYz1naShjKSxvPXBpKG8pLG8uX3RyZWUuYW5jZXN0b3I9bix1PWEuX3RyZWUucHJlbGltK2Yt
aS5fdHJlZS5wcmVsaW0tcytlKGEsaSksdT4wJiYoX2koYmkoYSxuLHIpLG4sdSkscys9dSxsKz11
KSxmKz1hLl90cmVlLm1vZCxzKz1pLl90cmVlLm1vZCxoKz1jLl90cmVlLm1vZCxsKz1vLl90cmVl
Lm1vZDthJiYhcGkobykmJihvLl90cmVlLnRocmVhZD1hLG8uX3RyZWUubW9kKz1mLWwpLGkmJiFn
aShjKSYmKGMuX3RyZWUudGhyZWFkPWksYy5fdHJlZS5tb2QrPXMtaCxyPW4pfXJldHVybiByfXZh
ciBzPXQuY2FsbCh0aGlzLG4saSksbD1zWzBdO3hpKGwsZnVuY3Rpb24obix0KXtuLl90cmVlPXth
bmNlc3RvcjpuLHByZWxpbTowLG1vZDowLGNoYW5nZTowLHNoaWZ0OjAsbnVtYmVyOnQ/dC5fdHJl
ZS5udW1iZXIrMTowfX0pLG8obCksYShsLC1sLl90cmVlLnByZWxpbSk7dmFyIGY9dmkobCxtaSks
aD12aShsLGRpKSxnPXZpKGwseWkpLHA9Zi54LWUoZixoKS8yLHY9aC54K2UoaCxmKS8yLGQ9Zy5k
ZXB0aHx8MTtyZXR1cm4geGkobCx1P2Z1bmN0aW9uKG4pe24ueCo9clswXSxuLnk9bi5kZXB0aCpy
WzFdLGRlbGV0ZSBuLl90cmVlfTpmdW5jdGlvbihuKXtuLng9KG4ueC1wKS8odi1wKSpyWzBdLG4u
eT1uLmRlcHRoL2QqclsxXSxkZWxldGUgbi5fdHJlZX0pLHN9dmFyIHQ9R28ubGF5b3V0LmhpZXJh
cmNoeSgpLnNvcnQobnVsbCkudmFsdWUobnVsbCksZT1oaSxyPVsxLDFdLHU9ITE7cmV0dXJuIG4u
c2VwYXJhdGlvbj1mdW5jdGlvbih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oZT10LG4pOmV9
LG4uc2l6ZT1mdW5jdGlvbih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8odT1udWxsPT0ocj10
KSxuKTp1P251bGw6cn0sbi5ub2RlU2l6ZT1mdW5jdGlvbih0KXtyZXR1cm4gYXJndW1lbnRzLmxl
bmd0aD8odT1udWxsIT0ocj10KSxuKTp1P3I6bnVsbH0sV3Uobix0KX0sR28ubGF5b3V0LnBhY2s9
ZnVuY3Rpb24oKXtmdW5jdGlvbiBuKG4saSl7dmFyIG89ZS5jYWxsKHRoaXMsbixpKSxhPW9bMF0s
Yz11WzBdLHM9dVsxXSxsPW51bGw9PXQ/TWF0aC5zcXJ0OiJmdW5jdGlvbiI9PXR5cGVvZiB0P3Q6
ZnVuY3Rpb24oKXtyZXR1cm4gdH07aWYoYS54PWEueT0wLHhpKGEsZnVuY3Rpb24obil7bi5yPSts
KG4udmFsdWUpfSkseGkoYSxBaSkscil7dmFyIGY9cioodD8xOk1hdGgubWF4KDIqYS5yL2MsMiph
LnIvcykpLzI7eGkoYSxmdW5jdGlvbihuKXtuLnIrPWZ9KSx4aShhLEFpKSx4aShhLGZ1bmN0aW9u
KG4pe24uci09Zn0pfXJldHVybiBMaShhLGMvMixzLzIsdD8xOjEvTWF0aC5tYXgoMiphLnIvYywy
KmEuci9zKSksb312YXIgdCxlPUdvLmxheW91dC5oaWVyYXJjaHkoKS5zb3J0KHdpKSxyPTAsdT1b
MSwxXTtyZXR1cm4gbi5zaXplPWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyh1
PXQsbik6dX0sbi5yYWRpdXM9ZnVuY3Rpb24oZSl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KHQ9
bnVsbD09ZXx8ImZ1bmN0aW9uIj09dHlwZW9mIGU/ZTorZSxuKTp0fSxuLnBhZGRpbmc9ZnVuY3Rp
b24odCl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KHI9K3Qsbik6cn0sV3UobixlKX0sR28ubGF5
b3V0LmNsdXN0ZXI9ZnVuY3Rpb24oKXtmdW5jdGlvbiBuKG4saSl7dmFyIG8sYT10LmNhbGwodGhp
cyxuLGkpLGM9YVswXSxzPTA7eGkoYyxmdW5jdGlvbihuKXt2YXIgdD1uLmNoaWxkcmVuO3QmJnQu
bGVuZ3RoPyhuLng9emkodCksbi55PXFpKHQpKToobi54PW8/cys9ZShuLG8pOjAsbi55PTAsbz1u
KX0pO3ZhciBsPVJpKGMpLGY9RGkoYyksaD1sLngtZShsLGYpLzIsZz1mLngrZShmLGwpLzI7cmV0
dXJuIHhpKGMsdT9mdW5jdGlvbihuKXtuLng9KG4ueC1jLngpKnJbMF0sbi55PShjLnktbi55KSpy
WzFdfTpmdW5jdGlvbihuKXtuLng9KG4ueC1oKS8oZy1oKSpyWzBdLG4ueT0oMS0oYy55P24ueS9j
Lnk6MSkpKnJbMV19KSxhfXZhciB0PUdvLmxheW91dC5oaWVyYXJjaHkoKS5zb3J0KG51bGwpLnZh
bHVlKG51bGwpLGU9aGkscj1bMSwxXSx1PSExO3JldHVybiBuLnNlcGFyYXRpb249ZnVuY3Rpb24o
dCl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KGU9dCxuKTplfSxuLnNpemU9ZnVuY3Rpb24odCl7
cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KHU9bnVsbD09KHI9dCksbik6dT9udWxsOnJ9LG4ubm9k
ZVNpemU9ZnVuY3Rpb24odCl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KHU9bnVsbCE9KHI9dCks
bik6dT9yOm51bGx9LFd1KG4sdCl9LEdvLmxheW91dC50cmVlbWFwPWZ1bmN0aW9uKCl7ZnVuY3Rp
b24gbihuLHQpe2Zvcih2YXIgZSxyLHU9LTEsaT1uLmxlbmd0aDsrK3U8aTspcj0oZT1uW3VdKS52
YWx1ZSooMD50PzA6dCksZS5hcmVhPWlzTmFOKHIpfHwwPj1yPzA6cn1mdW5jdGlvbiB0KGUpe3Zh
ciBpPWUuY2hpbGRyZW47aWYoaSYmaS5sZW5ndGgpe3ZhciBvLGEsYyxzPWYoZSksbD1bXSxoPWku
c2xpY2UoKSxwPTEvMCx2PSJzbGljZSI9PT1nP3MuZHg6ImRpY2UiPT09Zz9zLmR5OiJzbGljZS1k
aWNlIj09PWc/MSZlLmRlcHRoP3MuZHk6cy5keDpNYXRoLm1pbihzLmR4LHMuZHkpO2ZvcihuKGgs
cy5keCpzLmR5L2UudmFsdWUpLGwuYXJlYT0wOyhjPWgubGVuZ3RoKT4wOylsLnB1c2gobz1oW2Mt
MV0pLGwuYXJlYSs9by5hcmVhLCJzcXVhcmlmeSIhPT1nfHwoYT1yKGwsdikpPD1wPyhoLnBvcCgp
LHA9YSk6KGwuYXJlYS09bC5wb3AoKS5hcmVhLHUobCx2LHMsITEpLHY9TWF0aC5taW4ocy5keCxz
LmR5KSxsLmxlbmd0aD1sLmFyZWE9MCxwPTEvMCk7bC5sZW5ndGgmJih1KGwsdixzLCEwKSxsLmxl
bmd0aD1sLmFyZWE9MCksaS5mb3JFYWNoKHQpfX1mdW5jdGlvbiBlKHQpe3ZhciByPXQuY2hpbGRy
ZW47aWYociYmci5sZW5ndGgpe3ZhciBpLG89Zih0KSxhPXIuc2xpY2UoKSxjPVtdO2ZvcihuKGEs
by5keCpvLmR5L3QudmFsdWUpLGMuYXJlYT0wO2k9YS5wb3AoKTspYy5wdXNoKGkpLGMuYXJlYSs9
aS5hcmVhLG51bGwhPWkueiYmKHUoYyxpLno/by5keDpvLmR5LG8sIWEubGVuZ3RoKSxjLmxlbmd0
aD1jLmFyZWE9MCk7ci5mb3JFYWNoKGUpfX1mdW5jdGlvbiByKG4sdCl7Zm9yKHZhciBlLHI9bi5h
cmVhLHU9MCxpPTEvMCxvPS0xLGE9bi5sZW5ndGg7KytvPGE7KShlPW5bb10uYXJlYSkmJihpPmUm
JihpPWUpLGU+dSYmKHU9ZSkpO3JldHVybiByKj1yLHQqPXQscj9NYXRoLm1heCh0KnUqcC9yLHIv
KHQqaSpwKSk6MS8wfWZ1bmN0aW9uIHUobix0LGUscil7dmFyIHUsaT0tMSxvPW4ubGVuZ3RoLGE9
ZS54LHM9ZS55LGw9dD9jKG4uYXJlYS90KTowO2lmKHQ9PWUuZHgpe2Zvcigocnx8bD5lLmR5KSYm
KGw9ZS5keSk7KytpPG87KXU9bltpXSx1Lng9YSx1Lnk9cyx1LmR5PWwsYSs9dS5keD1NYXRoLm1p
bihlLngrZS5keC1hLGw/Yyh1LmFyZWEvbCk6MCk7dS56PSEwLHUuZHgrPWUueCtlLmR4LWEsZS55
Kz1sLGUuZHktPWx9ZWxzZXtmb3IoKHJ8fGw+ZS5keCkmJihsPWUuZHgpOysraTxvOyl1PW5baV0s
dS54PWEsdS55PXMsdS5keD1sLHMrPXUuZHk9TWF0aC5taW4oZS55K2UuZHktcyxsP2ModS5hcmVh
L2wpOjApO3Uuej0hMSx1LmR5Kz1lLnkrZS5keS1zLGUueCs9bCxlLmR4LT1sfX1mdW5jdGlvbiBp
KHIpe3ZhciB1PW98fGEociksaT11WzBdO3JldHVybiBpLng9MCxpLnk9MCxpLmR4PXNbMF0saS5k
eT1zWzFdLG8mJmEucmV2YWx1ZShpKSxuKFtpXSxpLmR4KmkuZHkvaS52YWx1ZSksKG8/ZTp0KShp
KSxoJiYobz11KSx1fXZhciBvLGE9R28ubGF5b3V0LmhpZXJhcmNoeSgpLGM9TWF0aC5yb3VuZCxz
PVsxLDFdLGw9bnVsbCxmPVBpLGg9ITEsZz0ic3F1YXJpZnkiLHA9LjUqKDErTWF0aC5zcXJ0KDUp
KTtyZXR1cm4gaS5zaXplPWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhzPW4s
aSk6c30saS5wYWRkaW5nPWZ1bmN0aW9uKG4pe2Z1bmN0aW9uIHQodCl7dmFyIGU9bi5jYWxsKGks
dCx0LmRlcHRoKTtyZXR1cm4gbnVsbD09ZT9QaSh0KTpVaSh0LCJudW1iZXIiPT10eXBlb2YgZT9b
ZSxlLGUsZV06ZSl9ZnVuY3Rpb24gZSh0KXtyZXR1cm4gVWkodCxuKX1pZighYXJndW1lbnRzLmxl
bmd0aClyZXR1cm4gbDt2YXIgcjtyZXR1cm4gZj1udWxsPT0obD1uKT9QaToiZnVuY3Rpb24iPT0o
cj10eXBlb2Ygbik/dDoibnVtYmVyIj09PXI/KG49W24sbixuLG5dLGUpOmUsaX0saS5yb3VuZD1m
dW5jdGlvbihuKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oYz1uP01hdGgucm91bmQ6TnVtYmVy
LGkpOmMhPU51bWJlcn0saS5zdGlja3k9ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5sZW5n
dGg/KGg9bixvPW51bGwsaSk6aH0saS5yYXRpbz1mdW5jdGlvbihuKXtyZXR1cm4gYXJndW1lbnRz
Lmxlbmd0aD8ocD1uLGkpOnB9LGkubW9kZT1mdW5jdGlvbihuKXtyZXR1cm4gYXJndW1lbnRzLmxl
bmd0aD8oZz1uKyIiLGkpOmd9LFd1KGksYSl9LEdvLnJhbmRvbT17bm9ybWFsOmZ1bmN0aW9uKG4s
dCl7dmFyIGU9YXJndW1lbnRzLmxlbmd0aDtyZXR1cm4gMj5lJiYodD0xKSwxPmUmJihuPTApLGZ1
bmN0aW9uKCl7dmFyIGUscix1O2RvIGU9MipNYXRoLnJhbmRvbSgpLTEscj0yKk1hdGgucmFuZG9t
KCktMSx1PWUqZStyKnI7d2hpbGUoIXV8fHU+MSk7cmV0dXJuIG4rdCplKk1hdGguc3FydCgtMipN
YXRoLmxvZyh1KS91KX19LGxvZ05vcm1hbDpmdW5jdGlvbigpe3ZhciBuPUdvLnJhbmRvbS5ub3Jt
YWwuYXBwbHkoR28sYXJndW1lbnRzKTtyZXR1cm4gZnVuY3Rpb24oKXtyZXR1cm4gTWF0aC5leHAo
bigpKX19LGJhdGVzOmZ1bmN0aW9uKG4pe3ZhciB0PUdvLnJhbmRvbS5pcndpbkhhbGwobik7cmV0
dXJuIGZ1bmN0aW9uKCl7cmV0dXJuIHQoKS9ufX0saXJ3aW5IYWxsOmZ1bmN0aW9uKG4pe3JldHVy
biBmdW5jdGlvbigpe2Zvcih2YXIgdD0wLGU9MDtuPmU7ZSsrKXQrPU1hdGgucmFuZG9tKCk7cmV0
dXJuIHR9fX0sR28uc2NhbGU9e307dmFyIHZzPXtmbG9vcjpBdCxjZWlsOkF0fTtHby5zY2FsZS5s
aW5lYXI9ZnVuY3Rpb24oKXtyZXR1cm4gWmkoWzAsMV0sWzAsMV0sZHUsITEpfTt2YXIgZHM9e3M6
MSxnOjEscDoxLHI6MSxlOjF9O0dvLnNjYWxlLmxvZz1mdW5jdGlvbigpe3JldHVybiBLaShHby5z
Y2FsZS5saW5lYXIoKS5kb21haW4oWzAsMV0pLDEwLCEwLFsxLDEwXSl9O3ZhciBtcz1Hby5mb3Jt
YXQoIi4wZSIpLHlzPXtmbG9vcjpmdW5jdGlvbihuKXtyZXR1cm4tTWF0aC5jZWlsKC1uKX0sY2Vp
bDpmdW5jdGlvbihuKXtyZXR1cm4tTWF0aC5mbG9vcigtbil9fTtHby5zY2FsZS5wb3c9ZnVuY3Rp
b24oKXtyZXR1cm4gUWkoR28uc2NhbGUubGluZWFyKCksMSxbMCwxXSl9LEdvLnNjYWxlLnNxcnQ9
ZnVuY3Rpb24oKXtyZXR1cm4gR28uc2NhbGUucG93KCkuZXhwb25lbnQoLjUpfSxHby5zY2FsZS5v
cmRpbmFsPWZ1bmN0aW9uKCl7cmV0dXJuIHRvKFtdLHt0OiJyYW5nZSIsYTpbW11dfSl9LEdvLnNj
YWxlLmNhdGVnb3J5MTA9ZnVuY3Rpb24oKXtyZXR1cm4gR28uc2NhbGUub3JkaW5hbCgpLnJhbmdl
KHhzKX0sR28uc2NhbGUuY2F0ZWdvcnkyMD1mdW5jdGlvbigpe3JldHVybiBHby5zY2FsZS5vcmRp
bmFsKCkucmFuZ2UoTXMpfSxHby5zY2FsZS5jYXRlZ29yeTIwYj1mdW5jdGlvbigpe3JldHVybiBH
by5zY2FsZS5vcmRpbmFsKCkucmFuZ2UoX3MpfSxHby5zY2FsZS5jYXRlZ29yeTIwYz1mdW5jdGlv
bigpe3JldHVybiBHby5zY2FsZS5vcmRpbmFsKCkucmFuZ2UoYnMpfTt2YXIgeHM9WzIwNjIyNjAs
MTY3NDQyMDYsMjkyNDU4OCwxNDAzNDcyOCw5NzI1ODg1LDkxOTcxMzEsMTQ5MDczMzAsODM1NTcx
MSwxMjM2OTE4NiwxNTU2MTc1XS5tYXAobXQpLE1zPVsyMDYyMjYwLDExNDU0NDQwLDE2NzQ0MjA2
LDE2NzU5NjcyLDI5MjQ1ODgsMTAwMTg2OTgsMTQwMzQ3MjgsMTY3NTA3NDIsOTcyNTg4NSwxMjk1
NTg2MSw5MTk3MTMxLDEyODg1MTQwLDE0OTA3MzMwLDE2MjM0MTk0LDgzNTU3MTEsMTMwOTI4MDcs
MTIzNjkxODYsMTQ0MDg1ODksMTU1NjE3NSwxMDQxMDcyNV0ubWFwKG10KSxfcz1bMzc1MDc3Nyw1
Mzk1NjE5LDcwNDA3MTksMTAyNjQyODYsNjUxOTA5Nyw5MjE2NTk0LDExOTE1MTE1LDEzNTU2NjM2
LDkyMDI5OTMsMTI0MjY4MDksMTUxODY1MTQsMTUxOTA5MzIsODY2NjE2OSwxMTM1NjQ5MCwxNDA0
OTY0MywxNTE3NzM3Miw4MDc3NjgzLDEwODM0MzI0LDEzNTI4NTA5LDE0NTg5NjU0XS5tYXAobXQp
LGJzPVszMjQ0NzMzLDcwNTcxMTAsMTA0MDY2MjUsMTMwMzI0MzEsMTUwOTUwNTMsMTY2MTY3NjQs
MTY2MjUyNTksMTY2MzQwMTgsMzI1MzA3Niw3NjUyNDcwLDEwNjA3MDAzLDEzMTAxNTA0LDc2OTUy
ODEsMTAzOTQzMTIsMTIzNjkzNzIsMTQzNDI4OTEsNjUxMzUwNyw5ODY4OTUwLDEyNDM0ODc3LDE0
Mjc3MDgxXS5tYXAobXQpO0dvLnNjYWxlLnF1YW50aWxlPWZ1bmN0aW9uKCl7cmV0dXJuIGVvKFtd
LFtdKX0sR28uc2NhbGUucXVhbnRpemU9ZnVuY3Rpb24oKXtyZXR1cm4gcm8oMCwxLFswLDFdKX0s
R28uc2NhbGUudGhyZXNob2xkPWZ1bmN0aW9uKCl7cmV0dXJuIHVvKFsuNV0sWzAsMV0pfSxHby5z
Y2FsZS5pZGVudGl0eT1mdW5jdGlvbigpe3JldHVybiBpbyhbMCwxXSl9LEdvLnN2Zz17fSxHby5z
dmcuYXJjPWZ1bmN0aW9uKCl7ZnVuY3Rpb24gbigpe3ZhciBuPXQuYXBwbHkodGhpcyxhcmd1bWVu
dHMpLGk9ZS5hcHBseSh0aGlzLGFyZ3VtZW50cyksbz1yLmFwcGx5KHRoaXMsYXJndW1lbnRzKSt3
cyxhPXUuYXBwbHkodGhpcyxhcmd1bWVudHMpK3dzLGM9KG8+YSYmKGM9byxvPWEsYT1jKSxhLW8p
LHM9Q2E+Yz8iMCI6IjEiLGw9TWF0aC5jb3MobyksZj1NYXRoLnNpbihvKSxoPU1hdGguY29zKGEp
LGc9TWF0aC5zaW4oYSk7CnJldHVybiBjPj1Tcz9uPyJNMCwiK2krIkEiK2krIiwiK2krIiAwIDEs
MSAwLCIrLWkrIkEiK2krIiwiK2krIiAwIDEsMSAwLCIraSsiTTAsIituKyJBIituKyIsIituKyIg
MCAxLDAgMCwiKy1uKyJBIituKyIsIituKyIgMCAxLDAgMCwiK24rIloiOiJNMCwiK2krIkEiK2kr
IiwiK2krIiAwIDEsMSAwLCIrLWkrIkEiK2krIiwiK2krIiAwIDEsMSAwLCIraSsiWiI6bj8iTSIr
aSpsKyIsIitpKmYrIkEiK2krIiwiK2krIiAwICIrcysiLDEgIitpKmgrIiwiK2kqZysiTCIrbipo
KyIsIituKmcrIkEiK24rIiwiK24rIiAwICIrcysiLDAgIituKmwrIiwiK24qZisiWiI6Ik0iK2kq
bCsiLCIraSpmKyJBIitpKyIsIitpKyIgMCAiK3MrIiwxICIraSpoKyIsIitpKmcrIkwwLDAiKyJa
In12YXIgdD1vbyxlPWFvLHI9Y28sdT1zbztyZXR1cm4gbi5pbm5lclJhZGl1cz1mdW5jdGlvbihl
KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8odD1FdChlKSxuKTp0fSxuLm91dGVyUmFkaXVzPWZ1
bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhlPUV0KHQpLG4pOmV9LG4uc3RhcnRB
bmdsZT1mdW5jdGlvbih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8ocj1FdCh0KSxuKTpyfSxu
LmVuZEFuZ2xlPWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyh1PUV0KHQpLG4p
OnV9LG4uY2VudHJvaWQ9ZnVuY3Rpb24oKXt2YXIgbj0odC5hcHBseSh0aGlzLGFyZ3VtZW50cykr
ZS5hcHBseSh0aGlzLGFyZ3VtZW50cykpLzIsaT0oci5hcHBseSh0aGlzLGFyZ3VtZW50cykrdS5h
cHBseSh0aGlzLGFyZ3VtZW50cykpLzIrd3M7cmV0dXJuW01hdGguY29zKGkpKm4sTWF0aC5zaW4o
aSkqbl19LG59O3ZhciB3cz0tTGEsU3M9TmEtVGE7R28uc3ZnLmxpbmU9ZnVuY3Rpb24oKXtyZXR1
cm4gbG8oQXQpfTt2YXIga3M9R28ubWFwKHtsaW5lYXI6Zm8sImxpbmVhci1jbG9zZWQiOmhvLHN0
ZXA6Z28sInN0ZXAtYmVmb3JlIjpwbywic3RlcC1hZnRlciI6dm8sYmFzaXM6Ym8sImJhc2lzLW9w
ZW4iOndvLCJiYXNpcy1jbG9zZWQiOlNvLGJ1bmRsZTprbyxjYXJkaW5hbDp4bywiY2FyZGluYWwt
b3BlbiI6bW8sImNhcmRpbmFsLWNsb3NlZCI6eW8sbW9ub3RvbmU6VG99KTtrcy5mb3JFYWNoKGZ1
bmN0aW9uKG4sdCl7dC5rZXk9bix0LmNsb3NlZD0vLWNsb3NlZCQvLnRlc3Qobil9KTt2YXIgRXM9
WzAsMi8zLDEvMywwXSxBcz1bMCwxLzMsMi8zLDBdLENzPVswLDEvNiwyLzMsMS82XTtHby5zdmcu
bGluZS5yYWRpYWw9ZnVuY3Rpb24oKXt2YXIgbj1sbyhxbyk7cmV0dXJuIG4ucmFkaXVzPW4ueCxk
ZWxldGUgbi54LG4uYW5nbGU9bi55LGRlbGV0ZSBuLnksbn0scG8ucmV2ZXJzZT12byx2by5yZXZl
cnNlPXBvLEdvLnN2Zy5hcmVhPWZ1bmN0aW9uKCl7cmV0dXJuIHpvKEF0KX0sR28uc3ZnLmFyZWEu
cmFkaWFsPWZ1bmN0aW9uKCl7dmFyIG49em8ocW8pO3JldHVybiBuLnJhZGl1cz1uLngsZGVsZXRl
IG4ueCxuLmlubmVyUmFkaXVzPW4ueDAsZGVsZXRlIG4ueDAsbi5vdXRlclJhZGl1cz1uLngxLGRl
bGV0ZSBuLngxLG4uYW5nbGU9bi55LGRlbGV0ZSBuLnksbi5zdGFydEFuZ2xlPW4ueTAsZGVsZXRl
IG4ueTAsbi5lbmRBbmdsZT1uLnkxLGRlbGV0ZSBuLnkxLG59LEdvLnN2Zy5jaG9yZD1mdW5jdGlv
bigpe2Z1bmN0aW9uIG4obixhKXt2YXIgYz10KHRoaXMsaSxuLGEpLHM9dCh0aGlzLG8sbixhKTty
ZXR1cm4iTSIrYy5wMCtyKGMucixjLnAxLGMuYTEtYy5hMCkrKGUoYyxzKT91KGMucixjLnAxLGMu
cixjLnAwKTp1KGMucixjLnAxLHMucixzLnAwKStyKHMucixzLnAxLHMuYTEtcy5hMCkrdShzLnIs
cy5wMSxjLnIsYy5wMCkpKyJaIn1mdW5jdGlvbiB0KG4sdCxlLHIpe3ZhciB1PXQuY2FsbChuLGUs
ciksaT1hLmNhbGwobix1LHIpLG89Yy5jYWxsKG4sdSxyKSt3cyxsPXMuY2FsbChuLHUscikrd3M7
cmV0dXJue3I6aSxhMDpvLGExOmwscDA6W2kqTWF0aC5jb3MobyksaSpNYXRoLnNpbihvKV0scDE6
W2kqTWF0aC5jb3MobCksaSpNYXRoLnNpbihsKV19fWZ1bmN0aW9uIGUobix0KXtyZXR1cm4gbi5h
MD09dC5hMCYmbi5hMT09dC5hMX1mdW5jdGlvbiByKG4sdCxlKXtyZXR1cm4iQSIrbisiLCIrbisi
IDAgIisgKyhlPkNhKSsiLDEgIit0fWZ1bmN0aW9uIHUobix0LGUscil7cmV0dXJuIlEgMCwwICIr
cn12YXIgaT1tcixvPXlyLGE9Um8sYz1jbyxzPXNvO3JldHVybiBuLnJhZGl1cz1mdW5jdGlvbih0
KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oYT1FdCh0KSxuKTphfSxuLnNvdXJjZT1mdW5jdGlv
bih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oaT1FdCh0KSxuKTppfSxuLnRhcmdldD1mdW5j
dGlvbih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8obz1FdCh0KSxuKTpvfSxuLnN0YXJ0QW5n
bGU9ZnVuY3Rpb24odCl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KGM9RXQodCksbik6Y30sbi5l
bmRBbmdsZT1mdW5jdGlvbih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8ocz1FdCh0KSxuKTpz
fSxufSxHby5zdmcuZGlhZ29uYWw9ZnVuY3Rpb24oKXtmdW5jdGlvbiBuKG4sdSl7dmFyIGk9dC5j
YWxsKHRoaXMsbix1KSxvPWUuY2FsbCh0aGlzLG4sdSksYT0oaS55K28ueSkvMixjPVtpLHt4Omku
eCx5OmF9LHt4Om8ueCx5OmF9LG9dO3JldHVybiBjPWMubWFwKHIpLCJNIitjWzBdKyJDIitjWzFd
KyIgIitjWzJdKyIgIitjWzNdfXZhciB0PW1yLGU9eXIscj1EbztyZXR1cm4gbi5zb3VyY2U9ZnVu
Y3Rpb24oZSl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KHQ9RXQoZSksbik6dH0sbi50YXJnZXQ9
ZnVuY3Rpb24odCl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KGU9RXQodCksbik6ZX0sbi5wcm9q
ZWN0aW9uPWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhyPXQsbik6cn0sbn0s
R28uc3ZnLmRpYWdvbmFsLnJhZGlhbD1mdW5jdGlvbigpe3ZhciBuPUdvLnN2Zy5kaWFnb25hbCgp
LHQ9RG8sZT1uLnByb2plY3Rpb247cmV0dXJuIG4ucHJvamVjdGlvbj1mdW5jdGlvbihuKXtyZXR1
cm4gYXJndW1lbnRzLmxlbmd0aD9lKFBvKHQ9bikpOnR9LG59LEdvLnN2Zy5zeW1ib2w9ZnVuY3Rp
b24oKXtmdW5jdGlvbiBuKG4scil7cmV0dXJuKE5zLmdldCh0LmNhbGwodGhpcyxuLHIpKXx8SG8p
KGUuY2FsbCh0aGlzLG4scikpfXZhciB0PWpvLGU9VW87cmV0dXJuIG4udHlwZT1mdW5jdGlvbihl
KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8odD1FdChlKSxuKTp0fSxuLnNpemU9ZnVuY3Rpb24o
dCl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KGU9RXQodCksbik6ZX0sbn07dmFyIE5zPUdvLm1h
cCh7Y2lyY2xlOkhvLGNyb3NzOmZ1bmN0aW9uKG4pe3ZhciB0PU1hdGguc3FydChuLzUpLzI7cmV0
dXJuIk0iKy0zKnQrIiwiKy10KyJIIistdCsiViIrLTMqdCsiSCIrdCsiViIrLXQrIkgiKzMqdCsi
ViIrdCsiSCIrdCsiViIrMyp0KyJIIistdCsiViIrdCsiSCIrLTMqdCsiWiJ9LGRpYW1vbmQ6ZnVu
Y3Rpb24obil7dmFyIHQ9TWF0aC5zcXJ0KG4vKDIqenMpKSxlPXQqenM7cmV0dXJuIk0wLCIrLXQr
IkwiK2UrIiwwIisiIDAsIit0KyIgIistZSsiLDAiKyJaIn0sc3F1YXJlOmZ1bmN0aW9uKG4pe3Zh
ciB0PU1hdGguc3FydChuKS8yO3JldHVybiJNIistdCsiLCIrLXQrIkwiK3QrIiwiKy10KyIgIit0
KyIsIit0KyIgIistdCsiLCIrdCsiWiJ9LCJ0cmlhbmdsZS1kb3duIjpmdW5jdGlvbihuKXt2YXIg
dD1NYXRoLnNxcnQobi9xcyksZT10KnFzLzI7cmV0dXJuIk0wLCIrZSsiTCIrdCsiLCIrLWUrIiAi
Ky10KyIsIistZSsiWiJ9LCJ0cmlhbmdsZS11cCI6ZnVuY3Rpb24obil7dmFyIHQ9TWF0aC5zcXJ0
KG4vcXMpLGU9dCpxcy8yO3JldHVybiJNMCwiKy1lKyJMIit0KyIsIitlKyIgIistdCsiLCIrZSsi
WiJ9fSk7R28uc3ZnLnN5bWJvbFR5cGVzPU5zLmtleXMoKTt2YXIgTHMsVHMscXM9TWF0aC5zcXJ0
KDMpLHpzPU1hdGgudGFuKDMwKnphKSxScz1bXSxEcz0wO1JzLmNhbGw9X2EuY2FsbCxScy5lbXB0
eT1fYS5lbXB0eSxScy5ub2RlPV9hLm5vZGUsUnMuc2l6ZT1fYS5zaXplLEdvLnRyYW5zaXRpb249
ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/THM/bi50cmFuc2l0aW9uKCk6bjpT
YS50cmFuc2l0aW9uKCl9LEdvLnRyYW5zaXRpb24ucHJvdG90eXBlPVJzLFJzLnNlbGVjdD1mdW5j
dGlvbihuKXt2YXIgdCxlLHIsdT10aGlzLmlkLGk9W107bj1iKG4pO2Zvcih2YXIgbz0tMSxhPXRo
aXMubGVuZ3RoOysrbzxhOyl7aS5wdXNoKHQ9W10pO2Zvcih2YXIgYz10aGlzW29dLHM9LTEsbD1j
Lmxlbmd0aDsrK3M8bDspKHI9Y1tzXSkmJihlPW4uY2FsbChyLHIuX19kYXRhX18scyxvKSk/KCJf
X2RhdGFfXyJpbiByJiYoZS5fX2RhdGFfXz1yLl9fZGF0YV9fKSxZbyhlLHMsdSxyLl9fdHJhbnNp
dGlvbl9fW3VdKSx0LnB1c2goZSkpOnQucHVzaChudWxsKX1yZXR1cm4gRm8oaSx1KX0sUnMuc2Vs
ZWN0QWxsPWZ1bmN0aW9uKG4pe3ZhciB0LGUscix1LGksbz10aGlzLmlkLGE9W107bj13KG4pO2Zv
cih2YXIgYz0tMSxzPXRoaXMubGVuZ3RoOysrYzxzOylmb3IodmFyIGw9dGhpc1tjXSxmPS0xLGg9
bC5sZW5ndGg7KytmPGg7KWlmKHI9bFtmXSl7aT1yLl9fdHJhbnNpdGlvbl9fW29dLGU9bi5jYWxs
KHIsci5fX2RhdGFfXyxmLGMpLGEucHVzaCh0PVtdKTtmb3IodmFyIGc9LTEscD1lLmxlbmd0aDsr
K2c8cDspKHU9ZVtnXSkmJllvKHUsZyxvLGkpLHQucHVzaCh1KX1yZXR1cm4gRm8oYSxvKX0sUnMu
ZmlsdGVyPWZ1bmN0aW9uKG4pe3ZhciB0LGUscix1PVtdOyJmdW5jdGlvbiIhPXR5cGVvZiBuJiYo
bj1SKG4pKTtmb3IodmFyIGk9MCxvPXRoaXMubGVuZ3RoO28+aTtpKyspe3UucHVzaCh0PVtdKTtm
b3IodmFyIGU9dGhpc1tpXSxhPTAsYz1lLmxlbmd0aDtjPmE7YSsrKShyPWVbYV0pJiZuLmNhbGwo
cixyLl9fZGF0YV9fLGEsaSkmJnQucHVzaChyKX1yZXR1cm4gRm8odSx0aGlzLmlkKX0sUnMudHdl
ZW49ZnVuY3Rpb24obix0KXt2YXIgZT10aGlzLmlkO3JldHVybiBhcmd1bWVudHMubGVuZ3RoPDI/
dGhpcy5ub2RlKCkuX190cmFuc2l0aW9uX19bZV0udHdlZW4uZ2V0KG4pOlAodGhpcyxudWxsPT10
P2Z1bmN0aW9uKHQpe3QuX190cmFuc2l0aW9uX19bZV0udHdlZW4ucmVtb3ZlKG4pfTpmdW5jdGlv
bihyKXtyLl9fdHJhbnNpdGlvbl9fW2VdLnR3ZWVuLnNldChuLHQpfSl9LFJzLmF0dHI9ZnVuY3Rp
b24obix0KXtmdW5jdGlvbiBlKCl7dGhpcy5yZW1vdmVBdHRyaWJ1dGUoYSl9ZnVuY3Rpb24gcigp
e3RoaXMucmVtb3ZlQXR0cmlidXRlTlMoYS5zcGFjZSxhLmxvY2FsKX1mdW5jdGlvbiB1KG4pe3Jl
dHVybiBudWxsPT1uP2U6KG4rPSIiLGZ1bmN0aW9uKCl7dmFyIHQsZT10aGlzLmdldEF0dHJpYnV0
ZShhKTtyZXR1cm4gZSE9PW4mJih0PW8oZSxuKSxmdW5jdGlvbihuKXt0aGlzLnNldEF0dHJpYnV0
ZShhLHQobikpfSl9KX1mdW5jdGlvbiBpKG4pe3JldHVybiBudWxsPT1uP3I6KG4rPSIiLGZ1bmN0
aW9uKCl7dmFyIHQsZT10aGlzLmdldEF0dHJpYnV0ZU5TKGEuc3BhY2UsYS5sb2NhbCk7cmV0dXJu
IGUhPT1uJiYodD1vKGUsbiksZnVuY3Rpb24obil7dGhpcy5zZXRBdHRyaWJ1dGVOUyhhLnNwYWNl
LGEubG9jYWwsdChuKSl9KX0pfWlmKGFyZ3VtZW50cy5sZW5ndGg8Mil7Zm9yKHQgaW4gbil0aGlz
LmF0dHIodCxuW3RdKTtyZXR1cm4gdGhpc312YXIgbz0idHJhbnNmb3JtIj09bj9IdTpkdSxhPUdv
Lm5zLnF1YWxpZnkobik7cmV0dXJuIE9vKHRoaXMsImF0dHIuIituLHQsYS5sb2NhbD9pOnUpfSxS
cy5hdHRyVHdlZW49ZnVuY3Rpb24obix0KXtmdW5jdGlvbiBlKG4sZSl7dmFyIHI9dC5jYWxsKHRo
aXMsbixlLHRoaXMuZ2V0QXR0cmlidXRlKHUpKTtyZXR1cm4gciYmZnVuY3Rpb24obil7dGhpcy5z
ZXRBdHRyaWJ1dGUodSxyKG4pKX19ZnVuY3Rpb24gcihuLGUpe3ZhciByPXQuY2FsbCh0aGlzLG4s
ZSx0aGlzLmdldEF0dHJpYnV0ZU5TKHUuc3BhY2UsdS5sb2NhbCkpO3JldHVybiByJiZmdW5jdGlv
bihuKXt0aGlzLnNldEF0dHJpYnV0ZU5TKHUuc3BhY2UsdS5sb2NhbCxyKG4pKX19dmFyIHU9R28u
bnMucXVhbGlmeShuKTtyZXR1cm4gdGhpcy50d2VlbigiYXR0ci4iK24sdS5sb2NhbD9yOmUpfSxS
cy5zdHlsZT1mdW5jdGlvbihuLHQsZSl7ZnVuY3Rpb24gcigpe3RoaXMuc3R5bGUucmVtb3ZlUHJv
cGVydHkobil9ZnVuY3Rpb24gdSh0KXtyZXR1cm4gbnVsbD09dD9yOih0Kz0iIixmdW5jdGlvbigp
e3ZhciByLHU9ZWEuZ2V0Q29tcHV0ZWRTdHlsZSh0aGlzLG51bGwpLmdldFByb3BlcnR5VmFsdWUo
bik7cmV0dXJuIHUhPT10JiYocj1kdSh1LHQpLGZ1bmN0aW9uKHQpe3RoaXMuc3R5bGUuc2V0UHJv
cGVydHkobixyKHQpLGUpfSl9KX12YXIgaT1hcmd1bWVudHMubGVuZ3RoO2lmKDM+aSl7aWYoInN0
cmluZyIhPXR5cGVvZiBuKXsyPmkmJih0PSIiKTtmb3IoZSBpbiBuKXRoaXMuc3R5bGUoZSxuW2Vd
LHQpO3JldHVybiB0aGlzfWU9IiJ9cmV0dXJuIE9vKHRoaXMsInN0eWxlLiIrbix0LHUpfSxScy5z
dHlsZVR3ZWVuPWZ1bmN0aW9uKG4sdCxlKXtmdW5jdGlvbiByKHIsdSl7dmFyIGk9dC5jYWxsKHRo
aXMscix1LGVhLmdldENvbXB1dGVkU3R5bGUodGhpcyxudWxsKS5nZXRQcm9wZXJ0eVZhbHVlKG4p
KTtyZXR1cm4gaSYmZnVuY3Rpb24odCl7dGhpcy5zdHlsZS5zZXRQcm9wZXJ0eShuLGkodCksZSl9
fXJldHVybiBhcmd1bWVudHMubGVuZ3RoPDMmJihlPSIiKSx0aGlzLnR3ZWVuKCJzdHlsZS4iK24s
cil9LFJzLnRleHQ9ZnVuY3Rpb24obil7cmV0dXJuIE9vKHRoaXMsInRleHQiLG4sSW8pfSxScy5y
ZW1vdmU9ZnVuY3Rpb24oKXtyZXR1cm4gdGhpcy5lYWNoKCJlbmQudHJhbnNpdGlvbiIsZnVuY3Rp
b24oKXt2YXIgbjt0aGlzLl9fdHJhbnNpdGlvbl9fLmNvdW50PDImJihuPXRoaXMucGFyZW50Tm9k
ZSkmJm4ucmVtb3ZlQ2hpbGQodGhpcyl9KX0sUnMuZWFzZT1mdW5jdGlvbihuKXt2YXIgdD10aGlz
LmlkO3JldHVybiBhcmd1bWVudHMubGVuZ3RoPDE/dGhpcy5ub2RlKCkuX190cmFuc2l0aW9uX19b
dF0uZWFzZTooImZ1bmN0aW9uIiE9dHlwZW9mIG4mJihuPUdvLmVhc2UuYXBwbHkoR28sYXJndW1l
bnRzKSksUCh0aGlzLGZ1bmN0aW9uKGUpe2UuX190cmFuc2l0aW9uX19bdF0uZWFzZT1ufSkpfSxS
cy5kZWxheT1mdW5jdGlvbihuKXt2YXIgdD10aGlzLmlkO3JldHVybiBhcmd1bWVudHMubGVuZ3Ro
PDE/dGhpcy5ub2RlKCkuX190cmFuc2l0aW9uX19bdF0uZGVsYXk6UCh0aGlzLCJmdW5jdGlvbiI9
PXR5cGVvZiBuP2Z1bmN0aW9uKGUscix1KXtlLl9fdHJhbnNpdGlvbl9fW3RdLmRlbGF5PStuLmNh
bGwoZSxlLl9fZGF0YV9fLHIsdSl9OihuPStuLGZ1bmN0aW9uKGUpe2UuX190cmFuc2l0aW9uX19b
dF0uZGVsYXk9bn0pKX0sUnMuZHVyYXRpb249ZnVuY3Rpb24obil7dmFyIHQ9dGhpcy5pZDtyZXR1
cm4gYXJndW1lbnRzLmxlbmd0aDwxP3RoaXMubm9kZSgpLl9fdHJhbnNpdGlvbl9fW3RdLmR1cmF0
aW9uOlAodGhpcywiZnVuY3Rpb24iPT10eXBlb2Ygbj9mdW5jdGlvbihlLHIsdSl7ZS5fX3RyYW5z
aXRpb25fX1t0XS5kdXJhdGlvbj1NYXRoLm1heCgxLG4uY2FsbChlLGUuX19kYXRhX18scix1KSl9
OihuPU1hdGgubWF4KDEsbiksZnVuY3Rpb24oZSl7ZS5fX3RyYW5zaXRpb25fX1t0XS5kdXJhdGlv
bj1ufSkpfSxScy5lYWNoPWZ1bmN0aW9uKG4sdCl7dmFyIGU9dGhpcy5pZDtpZihhcmd1bWVudHMu
bGVuZ3RoPDIpe3ZhciByPVRzLHU9THM7THM9ZSxQKHRoaXMsZnVuY3Rpb24odCxyLHUpe1RzPXQu
X190cmFuc2l0aW9uX19bZV0sbi5jYWxsKHQsdC5fX2RhdGFfXyxyLHUpfSksVHM9cixMcz11fWVs
c2UgUCh0aGlzLGZ1bmN0aW9uKHIpe3ZhciB1PXIuX190cmFuc2l0aW9uX19bZV07KHUuZXZlbnR8
fCh1LmV2ZW50PUdvLmRpc3BhdGNoKCJzdGFydCIsImVuZCIpKSkub24obix0KX0pO3JldHVybiB0
aGlzfSxScy50cmFuc2l0aW9uPWZ1bmN0aW9uKCl7Zm9yKHZhciBuLHQsZSxyLHU9dGhpcy5pZCxp
PSsrRHMsbz1bXSxhPTAsYz10aGlzLmxlbmd0aDtjPmE7YSsrKXtvLnB1c2gobj1bXSk7Zm9yKHZh
ciB0PXRoaXNbYV0scz0wLGw9dC5sZW5ndGg7bD5zO3MrKykoZT10W3NdKSYmKHI9T2JqZWN0LmNy
ZWF0ZShlLl9fdHJhbnNpdGlvbl9fW3VdKSxyLmRlbGF5Kz1yLmR1cmF0aW9uLFlvKGUscyxpLHIp
KSxuLnB1c2goZSl9cmV0dXJuIEZvKG8saSl9LEdvLnN2Zy5heGlzPWZ1bmN0aW9uKCl7ZnVuY3Rp
b24gbihuKXtuLmVhY2goZnVuY3Rpb24oKXt2YXIgbixzPUdvLnNlbGVjdCh0aGlzKSxsPXRoaXMu
X19jaGFydF9ffHxlLGY9dGhpcy5fX2NoYXJ0X189ZS5jb3B5KCksaD1udWxsPT1jP2YudGlja3M/
Zi50aWNrcy5hcHBseShmLGEpOmYuZG9tYWluKCk6YyxnPW51bGw9PXQ/Zi50aWNrRm9ybWF0P2Yu
dGlja0Zvcm1hdC5hcHBseShmLGEpOkF0OnQscD1zLnNlbGVjdEFsbCgiLnRpY2siKS5kYXRhKGgs
Ziksdj1wLmVudGVyKCkuaW5zZXJ0KCJnIiwiLmRvbWFpbiIpLmF0dHIoImNsYXNzIiwidGljayIp
LnN0eWxlKCJvcGFjaXR5IixUYSksZD1Hby50cmFuc2l0aW9uKHAuZXhpdCgpKS5zdHlsZSgib3Bh
Y2l0eSIsVGEpLnJlbW92ZSgpLG09R28udHJhbnNpdGlvbihwLm9yZGVyKCkpLnN0eWxlKCJvcGFj
aXR5IiwxKSx5PUhpKGYpLHg9cy5zZWxlY3RBbGwoIi5kb21haW4iKS5kYXRhKFswXSksTT0oeC5l
bnRlcigpLmFwcGVuZCgicGF0aCIpLmF0dHIoImNsYXNzIiwiZG9tYWluIiksR28udHJhbnNpdGlv
bih4KSk7di5hcHBlbmQoImxpbmUiKSx2LmFwcGVuZCgidGV4dCIpO3ZhciBfPXYuc2VsZWN0KCJs
aW5lIiksYj1tLnNlbGVjdCgibGluZSIpLHc9cC5zZWxlY3QoInRleHQiKS50ZXh0KGcpLFM9di5z
ZWxlY3QoInRleHQiKSxrPW0uc2VsZWN0KCJ0ZXh0Iik7c3dpdGNoKHIpe2Nhc2UiYm90dG9tIjpu
PVpvLF8uYXR0cigieTIiLHUpLFMuYXR0cigieSIsTWF0aC5tYXgodSwwKStvKSxiLmF0dHIoIngy
IiwwKS5hdHRyKCJ5MiIsdSksay5hdHRyKCJ4IiwwKS5hdHRyKCJ5IixNYXRoLm1heCh1LDApK28p
LHcuYXR0cigiZHkiLCIuNzFlbSIpLnN0eWxlKCJ0ZXh0LWFuY2hvciIsIm1pZGRsZSIpLE0uYXR0
cigiZCIsIk0iK3lbMF0rIiwiK2krIlYwSCIreVsxXSsiViIraSk7YnJlYWs7Y2FzZSJ0b3AiOm49
Wm8sXy5hdHRyKCJ5MiIsLXUpLFMuYXR0cigieSIsLShNYXRoLm1heCh1LDApK28pKSxiLmF0dHIo
IngyIiwwKS5hdHRyKCJ5MiIsLXUpLGsuYXR0cigieCIsMCkuYXR0cigieSIsLShNYXRoLm1heCh1
LDApK28pKSx3LmF0dHIoImR5IiwiMGVtIikuc3R5bGUoInRleHQtYW5jaG9yIiwibWlkZGxlIiks
TS5hdHRyKCJkIiwiTSIreVswXSsiLCIrLWkrIlYwSCIreVsxXSsiViIrLWkpO2JyZWFrO2Nhc2Ui
bGVmdCI6bj1WbyxfLmF0dHIoIngyIiwtdSksUy5hdHRyKCJ4IiwtKE1hdGgubWF4KHUsMCkrbykp
LGIuYXR0cigieDIiLC11KS5hdHRyKCJ5MiIsMCksay5hdHRyKCJ4IiwtKE1hdGgubWF4KHUsMCkr
bykpLmF0dHIoInkiLDApLHcuYXR0cigiZHkiLCIuMzJlbSIpLnN0eWxlKCJ0ZXh0LWFuY2hvciIs
ImVuZCIpLE0uYXR0cigiZCIsIk0iKy1pKyIsIit5WzBdKyJIMFYiK3lbMV0rIkgiKy1pKTticmVh
aztjYXNlInJpZ2h0IjpuPVZvLF8uYXR0cigieDIiLHUpLFMuYXR0cigieCIsTWF0aC5tYXgodSww
KStvKSxiLmF0dHIoIngyIix1KS5hdHRyKCJ5MiIsMCksay5hdHRyKCJ4IixNYXRoLm1heCh1LDAp
K28pLmF0dHIoInkiLDApLHcuYXR0cigiZHkiLCIuMzJlbSIpLnN0eWxlKCJ0ZXh0LWFuY2hvciIs
InN0YXJ0IiksTS5hdHRyKCJkIiwiTSIraSsiLCIreVswXSsiSDBWIit5WzFdKyJIIitpKX1pZihm
LnJhbmdlQmFuZCl7dmFyIEU9ZixBPUUucmFuZ2VCYW5kKCkvMjtsPWY9ZnVuY3Rpb24obil7cmV0
dXJuIEUobikrQX19ZWxzZSBsLnJhbmdlQmFuZD9sPWY6ZC5jYWxsKG4sZik7di5jYWxsKG4sbCks
bS5jYWxsKG4sZil9KX12YXIgdCxlPUdvLnNjYWxlLmxpbmVhcigpLHI9UHMsdT02LGk9NixvPTMs
YT1bMTBdLGM9bnVsbDtyZXR1cm4gbi5zY2FsZT1mdW5jdGlvbih0KXtyZXR1cm4gYXJndW1lbnRz
Lmxlbmd0aD8oZT10LG4pOmV9LG4ub3JpZW50PWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMu
bGVuZ3RoPyhyPXQgaW4gVXM/dCsiIjpQcyxuKTpyfSxuLnRpY2tzPWZ1bmN0aW9uKCl7cmV0dXJu
IGFyZ3VtZW50cy5sZW5ndGg/KGE9YXJndW1lbnRzLG4pOmF9LG4udGlja1ZhbHVlcz1mdW5jdGlv
bih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oYz10LG4pOmN9LG4udGlja0Zvcm1hdD1mdW5j
dGlvbihlKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8odD1lLG4pOnR9LG4udGlja1NpemU9ZnVu
Y3Rpb24odCl7dmFyIGU9YXJndW1lbnRzLmxlbmd0aDtyZXR1cm4gZT8odT0rdCxpPSthcmd1bWVu
dHNbZS0xXSxuKTp1fSxuLmlubmVyVGlja1NpemU9ZnVuY3Rpb24odCl7cmV0dXJuIGFyZ3VtZW50
cy5sZW5ndGg/KHU9K3Qsbik6dX0sbi5vdXRlclRpY2tTaXplPWZ1bmN0aW9uKHQpe3JldHVybiBh
cmd1bWVudHMubGVuZ3RoPyhpPSt0LG4pOml9LG4udGlja1BhZGRpbmc9ZnVuY3Rpb24odCl7cmV0
dXJuIGFyZ3VtZW50cy5sZW5ndGg/KG89K3Qsbik6b30sbi50aWNrU3ViZGl2aWRlPWZ1bmN0aW9u
KCl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGgmJm59LG59O3ZhciBQcz0iYm90dG9tIixVcz17dG9w
OjEscmlnaHQ6MSxib3R0b206MSxsZWZ0OjF9O0dvLnN2Zy5icnVzaD1mdW5jdGlvbigpe2Z1bmN0
aW9uIG4oaSl7aS5lYWNoKGZ1bmN0aW9uKCl7dmFyIGk9R28uc2VsZWN0KHRoaXMpLnN0eWxlKCJw
b2ludGVyLWV2ZW50cyIsImFsbCIpLnN0eWxlKCItd2Via2l0LXRhcC1oaWdobGlnaHQtY29sb3Ii
LCJyZ2JhKDAsMCwwLDApIikub24oIm1vdXNlZG93bi5icnVzaCIsdSkub24oInRvdWNoc3RhcnQu
YnJ1c2giLHUpLG89aS5zZWxlY3RBbGwoIi5iYWNrZ3JvdW5kIikuZGF0YShbMF0pO28uZW50ZXIo
KS5hcHBlbmQoInJlY3QiKS5hdHRyKCJjbGFzcyIsImJhY2tncm91bmQiKS5zdHlsZSgidmlzaWJp
bGl0eSIsImhpZGRlbiIpLnN0eWxlKCJjdXJzb3IiLCJjcm9zc2hhaXIiKSxpLnNlbGVjdEFsbCgi
LmV4dGVudCIpLmRhdGEoWzBdKS5lbnRlcigpLmFwcGVuZCgicmVjdCIpLmF0dHIoImNsYXNzIiwi
ZXh0ZW50Iikuc3R5bGUoImN1cnNvciIsIm1vdmUiKTt2YXIgYT1pLnNlbGVjdEFsbCgiLnJlc2l6
ZSIpLmRhdGEocCxBdCk7YS5leGl0KCkucmVtb3ZlKCksYS5lbnRlcigpLmFwcGVuZCgiZyIpLmF0
dHIoImNsYXNzIixmdW5jdGlvbihuKXtyZXR1cm4icmVzaXplICIrbn0pLnN0eWxlKCJjdXJzb3Ii
LGZ1bmN0aW9uKG4pe3JldHVybiBqc1tuXX0pLmFwcGVuZCgicmVjdCIpLmF0dHIoIngiLGZ1bmN0
aW9uKG4pe3JldHVybi9bZXddJC8udGVzdChuKT8tMzpudWxsfSkuYXR0cigieSIsZnVuY3Rpb24o
bil7cmV0dXJuL15bbnNdLy50ZXN0KG4pPy0zOm51bGx9KS5hdHRyKCJ3aWR0aCIsNikuYXR0cigi
aGVpZ2h0Iiw2KS5zdHlsZSgidmlzaWJpbGl0eSIsImhpZGRlbiIpLGEuc3R5bGUoImRpc3BsYXki
LG4uZW1wdHkoKT8ibm9uZSI6bnVsbCk7dmFyIGwsZj1Hby50cmFuc2l0aW9uKGkpLGg9R28udHJh
bnNpdGlvbihvKTtjJiYobD1IaShjKSxoLmF0dHIoIngiLGxbMF0pLmF0dHIoIndpZHRoIixsWzFd
LWxbMF0pLGUoZikpLHMmJihsPUhpKHMpLGguYXR0cigieSIsbFswXSkuYXR0cigiaGVpZ2h0Iixs
WzFdLWxbMF0pLHIoZikpLHQoZil9KX1mdW5jdGlvbiB0KG4pe24uc2VsZWN0QWxsKCIucmVzaXpl
IikuYXR0cigidHJhbnNmb3JtIixmdW5jdGlvbihuKXtyZXR1cm4idHJhbnNsYXRlKCIrbFsrL2Uk
Ly50ZXN0KG4pXSsiLCIrZlsrL15zLy50ZXN0KG4pXSsiKSJ9KX1mdW5jdGlvbiBlKG4pe24uc2Vs
ZWN0KCIuZXh0ZW50IikuYXR0cigieCIsbFswXSksbi5zZWxlY3RBbGwoIi5leHRlbnQsLm4+cmVj
dCwucz5yZWN0IikuYXR0cigid2lkdGgiLGxbMV0tbFswXSl9ZnVuY3Rpb24gcihuKXtuLnNlbGVj
dCgiLmV4dGVudCIpLmF0dHIoInkiLGZbMF0pLG4uc2VsZWN0QWxsKCIuZXh0ZW50LC5lPnJlY3Qs
Lnc+cmVjdCIpLmF0dHIoImhlaWdodCIsZlsxXS1mWzBdKX1mdW5jdGlvbiB1KCl7ZnVuY3Rpb24g
dSgpezMyPT1Hby5ldmVudC5rZXlDb2RlJiYoQ3x8KHg9bnVsbCxMWzBdLT1sWzFdLExbMV0tPWZb
MV0sQz0yKSx5KCkpfWZ1bmN0aW9uIHAoKXszMj09R28uZXZlbnQua2V5Q29kZSYmMj09QyYmKExb
MF0rPWxbMV0sTFsxXSs9ZlsxXSxDPTAseSgpKX1mdW5jdGlvbiB2KCl7dmFyIG49R28ubW91c2Uo
XyksdT0hMTtNJiYoblswXSs9TVswXSxuWzFdKz1NWzFdKSxDfHwoR28uZXZlbnQuYWx0S2V5Pyh4
fHwoeD1bKGxbMF0rbFsxXSkvMiwoZlswXStmWzFdKS8yXSksTFswXT1sWysoblswXTx4WzBdKV0s
TFsxXT1mWysoblsxXTx4WzFdKV0pOng9bnVsbCksRSYmZChuLGMsMCkmJihlKFMpLHU9ITApLEEm
JmQobixzLDEpJiYocihTKSx1PSEwKSx1JiYodChTKSx3KHt0eXBlOiJicnVzaCIsbW9kZTpDPyJt
b3ZlIjoicmVzaXplIn0pKX1mdW5jdGlvbiBkKG4sdCxlKXt2YXIgcix1LGE9SGkodCksYz1hWzBd
LHM9YVsxXSxwPUxbZV0sdj1lP2Y6bCxkPXZbMV0tdlswXTtyZXR1cm4gQyYmKGMtPXAscy09ZCtw
KSxyPShlP2c6aCk/TWF0aC5tYXgoYyxNYXRoLm1pbihzLG5bZV0pKTpuW2VdLEM/dT0ocis9cCkr
ZDooeCYmKHA9TWF0aC5tYXgoYyxNYXRoLm1pbihzLDIqeFtlXS1yKSkpLHI+cD8odT1yLHI9cCk6
dT1wKSx2WzBdIT1yfHx2WzFdIT11PyhlP289bnVsbDppPW51bGwsdlswXT1yLHZbMV09dSwhMCk6
dm9pZCAwfWZ1bmN0aW9uIG0oKXt2KCksUy5zdHlsZSgicG9pbnRlci1ldmVudHMiLCJhbGwiKS5z
ZWxlY3RBbGwoIi5yZXNpemUiKS5zdHlsZSgiZGlzcGxheSIsbi5lbXB0eSgpPyJub25lIjpudWxs
KSxHby5zZWxlY3QoImJvZHkiKS5zdHlsZSgiY3Vyc29yIixudWxsKSxULm9uKCJtb3VzZW1vdmUu
YnJ1c2giLG51bGwpLm9uKCJtb3VzZXVwLmJydXNoIixudWxsKS5vbigidG91Y2htb3ZlLmJydXNo
IixudWxsKS5vbigidG91Y2hlbmQuYnJ1c2giLG51bGwpLm9uKCJrZXlkb3duLmJydXNoIixudWxs
KS5vbigia2V5dXAuYnJ1c2giLG51bGwpLE4oKSx3KHt0eXBlOiJicnVzaGVuZCJ9KX12YXIgeCxN
LF89dGhpcyxiPUdvLnNlbGVjdChHby5ldmVudC50YXJnZXQpLHc9YS5vZihfLGFyZ3VtZW50cyks
Uz1Hby5zZWxlY3QoXyksaz1iLmRhdHVtKCksRT0hL14obnxzKSQvLnRlc3QoaykmJmMsQT0hL14o
ZXx3KSQvLnRlc3QoaykmJnMsQz1iLmNsYXNzZWQoImV4dGVudCIpLE49WSgpLEw9R28ubW91c2Uo
XyksVD1Hby5zZWxlY3QoZWEpLm9uKCJrZXlkb3duLmJydXNoIix1KS5vbigia2V5dXAuYnJ1c2gi
LHApO2lmKEdvLmV2ZW50LmNoYW5nZWRUb3VjaGVzP1Qub24oInRvdWNobW92ZS5icnVzaCIsdiku
b24oInRvdWNoZW5kLmJydXNoIixtKTpULm9uKCJtb3VzZW1vdmUuYnJ1c2giLHYpLm9uKCJtb3Vz
ZXVwLmJydXNoIixtKSxTLmludGVycnVwdCgpLnNlbGVjdEFsbCgiKiIpLmludGVycnVwdCgpLEMp
TFswXT1sWzBdLUxbMF0sTFsxXT1mWzBdLUxbMV07ZWxzZSBpZihrKXt2YXIgcT0rL3ckLy50ZXN0
KGspLHo9Ky9ebi8udGVzdChrKTtNPVtsWzEtcV0tTFswXSxmWzEtel0tTFsxXV0sTFswXT1sW3Fd
LExbMV09Zlt6XX1lbHNlIEdvLmV2ZW50LmFsdEtleSYmKHg9TC5zbGljZSgpKTtTLnN0eWxlKCJw
b2ludGVyLWV2ZW50cyIsIm5vbmUiKS5zZWxlY3RBbGwoIi5yZXNpemUiKS5zdHlsZSgiZGlzcGxh
eSIsbnVsbCksR28uc2VsZWN0KCJib2R5Iikuc3R5bGUoImN1cnNvciIsYi5zdHlsZSgiY3Vyc29y
IikpLHcoe3R5cGU6ImJydXNoc3RhcnQifSksdigpfXZhciBpLG8sYT1NKG4sImJydXNoc3RhcnQi
LCJicnVzaCIsImJydXNoZW5kIiksYz1udWxsLHM9bnVsbCxsPVswLDBdLGY9WzAsMF0saD0hMCxn
PSEwLHA9SHNbMF07cmV0dXJuIG4uZXZlbnQ9ZnVuY3Rpb24obil7bi5lYWNoKGZ1bmN0aW9uKCl7
dmFyIG49YS5vZih0aGlzLGFyZ3VtZW50cyksdD17eDpsLHk6ZixpOmksajpvfSxlPXRoaXMuX19j
aGFydF9ffHx0O3RoaXMuX19jaGFydF9fPXQsTHM/R28uc2VsZWN0KHRoaXMpLnRyYW5zaXRpb24o
KS5lYWNoKCJzdGFydC5icnVzaCIsZnVuY3Rpb24oKXtpPWUuaSxvPWUuaixsPWUueCxmPWUueSxu
KHt0eXBlOiJicnVzaHN0YXJ0In0pfSkudHdlZW4oImJydXNoOmJydXNoIixmdW5jdGlvbigpe3Zh
ciBlPW11KGwsdC54KSxyPW11KGYsdC55KTtyZXR1cm4gaT1vPW51bGwsZnVuY3Rpb24odSl7bD10
Lng9ZSh1KSxmPXQueT1yKHUpLG4oe3R5cGU6ImJydXNoIixtb2RlOiJyZXNpemUifSl9fSkuZWFj
aCgiZW5kLmJydXNoIixmdW5jdGlvbigpe2k9dC5pLG89dC5qLG4oe3R5cGU6ImJydXNoIixtb2Rl
OiJyZXNpemUifSksbih7dHlwZToiYnJ1c2hlbmQifSl9KToobih7dHlwZToiYnJ1c2hzdGFydCJ9
KSxuKHt0eXBlOiJicnVzaCIsbW9kZToicmVzaXplIn0pLG4oe3R5cGU6ImJydXNoZW5kIn0pKX0p
fSxuLng9ZnVuY3Rpb24odCl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KGM9dCxwPUhzWyFjPDwx
fCFzXSxuKTpjfSxuLnk9ZnVuY3Rpb24odCl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KHM9dCxw
PUhzWyFjPDwxfCFzXSxuKTpzfSxuLmNsYW1wPWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMu
bGVuZ3RoPyhjJiZzPyhoPSEhdFswXSxnPSEhdFsxXSk6Yz9oPSEhdDpzJiYoZz0hIXQpLG4pOmMm
JnM/W2gsZ106Yz9oOnM/ZzpudWxsfSxuLmV4dGVudD1mdW5jdGlvbih0KXt2YXIgZSxyLHUsYSxo
O3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhjJiYoZT10WzBdLHI9dFsxXSxzJiYoZT1lWzBdLHI9
clswXSksaT1bZSxyXSxjLmludmVydCYmKGU9YyhlKSxyPWMocikpLGU+ciYmKGg9ZSxlPXIscj1o
KSwoZSE9bFswXXx8ciE9bFsxXSkmJihsPVtlLHJdKSkscyYmKHU9dFswXSxhPXRbMV0sYyYmKHU9
dVsxXSxhPWFbMV0pLG89W3UsYV0scy5pbnZlcnQmJih1PXModSksYT1zKGEpKSx1PmEmJihoPXUs
dT1hLGE9aCksKHUhPWZbMF18fGEhPWZbMV0pJiYoZj1bdSxhXSkpLG4pOihjJiYoaT8oZT1pWzBd
LHI9aVsxXSk6KGU9bFswXSxyPWxbMV0sYy5pbnZlcnQmJihlPWMuaW52ZXJ0KGUpLHI9Yy5pbnZl
cnQocikpLGU+ciYmKGg9ZSxlPXIscj1oKSkpLHMmJihvPyh1PW9bMF0sYT1vWzFdKToodT1mWzBd
LGE9ZlsxXSxzLmludmVydCYmKHU9cy5pbnZlcnQodSksYT1zLmludmVydChhKSksdT5hJiYoaD11
LHU9YSxhPWgpKSksYyYmcz9bW2UsdV0sW3IsYV1dOmM/W2Uscl06cyYmW3UsYV0pfSxuLmNsZWFy
PWZ1bmN0aW9uKCl7cmV0dXJuIG4uZW1wdHkoKXx8KGw9WzAsMF0sZj1bMCwwXSxpPW89bnVsbCks
bn0sbi5lbXB0eT1mdW5jdGlvbigpe3JldHVybiEhYyYmbFswXT09bFsxXXx8ISFzJiZmWzBdPT1m
WzFdfSxHby5yZWJpbmQobixhLCJvbiIpfTt2YXIganM9e246Im5zLXJlc2l6ZSIsZToiZXctcmVz
aXplIixzOiJucy1yZXNpemUiLHc6ImV3LXJlc2l6ZSIsbnc6Im53c2UtcmVzaXplIixuZToibmVz
dy1yZXNpemUiLHNlOiJud3NlLXJlc2l6ZSIsc3c6Im5lc3ctcmVzaXplIn0sSHM9W1sibiIsImUi
LCJzIiwidyIsIm53IiwibmUiLCJzZSIsInN3Il0sWyJlIiwidyJdLFsibiIsInMiXSxbXV0sRnM9
aWMuZm9ybWF0PWZjLnRpbWVGb3JtYXQsT3M9RnMudXRjLElzPU9zKCIlWS0lbS0lZFQlSDolTTol
Uy4lTFoiKTtGcy5pc289RGF0ZS5wcm90b3R5cGUudG9JU09TdHJpbmcmJituZXcgRGF0ZSgiMjAw
MC0wMS0wMVQwMDowMDowMC4wMDBaIik/JG86SXMsJG8ucGFyc2U9ZnVuY3Rpb24obil7dmFyIHQ9
bmV3IERhdGUobik7cmV0dXJuIGlzTmFOKHQpP251bGw6dH0sJG8udG9TdHJpbmc9SXMudG9TdHJp
bmcsaWMuc2Vjb25kPUh0KGZ1bmN0aW9uKG4pe3JldHVybiBuZXcgb2MoMWUzKk1hdGguZmxvb3Io
bi8xZTMpKX0sZnVuY3Rpb24obix0KXtuLnNldFRpbWUobi5nZXRUaW1lKCkrMWUzKk1hdGguZmxv
b3IodCkpfSxmdW5jdGlvbihuKXtyZXR1cm4gbi5nZXRTZWNvbmRzKCl9KSxpYy5zZWNvbmRzPWlj
LnNlY29uZC5yYW5nZSxpYy5zZWNvbmRzLnV0Yz1pYy5zZWNvbmQudXRjLnJhbmdlLGljLm1pbnV0
ZT1IdChmdW5jdGlvbihuKXtyZXR1cm4gbmV3IG9jKDZlNCpNYXRoLmZsb29yKG4vNmU0KSl9LGZ1
bmN0aW9uKG4sdCl7bi5zZXRUaW1lKG4uZ2V0VGltZSgpKzZlNCpNYXRoLmZsb29yKHQpKX0sZnVu
Y3Rpb24obil7cmV0dXJuIG4uZ2V0TWludXRlcygpfSksaWMubWludXRlcz1pYy5taW51dGUucmFu
Z2UsaWMubWludXRlcy51dGM9aWMubWludXRlLnV0Yy5yYW5nZSxpYy5ob3VyPUh0KGZ1bmN0aW9u
KG4pe3ZhciB0PW4uZ2V0VGltZXpvbmVPZmZzZXQoKS82MDtyZXR1cm4gbmV3IG9jKDM2ZTUqKE1h
dGguZmxvb3Iobi8zNmU1LXQpK3QpKX0sZnVuY3Rpb24obix0KXtuLnNldFRpbWUobi5nZXRUaW1l
KCkrMzZlNSpNYXRoLmZsb29yKHQpKX0sZnVuY3Rpb24obil7cmV0dXJuIG4uZ2V0SG91cnMoKX0p
LGljLmhvdXJzPWljLmhvdXIucmFuZ2UsaWMuaG91cnMudXRjPWljLmhvdXIudXRjLnJhbmdlLGlj
Lm1vbnRoPUh0KGZ1bmN0aW9uKG4pe3JldHVybiBuPWljLmRheShuKSxuLnNldERhdGUoMSksbn0s
ZnVuY3Rpb24obix0KXtuLnNldE1vbnRoKG4uZ2V0TW9udGgoKSt0KX0sZnVuY3Rpb24obil7cmV0
dXJuIG4uZ2V0TW9udGgoKX0pLGljLm1vbnRocz1pYy5tb250aC5yYW5nZSxpYy5tb250aHMudXRj
PWljLm1vbnRoLnV0Yy5yYW5nZTt2YXIgWXM9WzFlMyw1ZTMsMTVlMywzZTQsNmU0LDNlNSw5ZTUs
MThlNSwzNmU1LDEwOGU1LDIxNmU1LDQzMmU1LDg2NGU1LDE3MjhlNSw2MDQ4ZTUsMjU5MmU2LDc3
NzZlNiwzMTUzNmU2XSxacz1bW2ljLnNlY29uZCwxXSxbaWMuc2Vjb25kLDVdLFtpYy5zZWNvbmQs
MTVdLFtpYy5zZWNvbmQsMzBdLFtpYy5taW51dGUsMV0sW2ljLm1pbnV0ZSw1XSxbaWMubWludXRl
LDE1XSxbaWMubWludXRlLDMwXSxbaWMuaG91ciwxXSxbaWMuaG91ciwzXSxbaWMuaG91ciw2XSxb
aWMuaG91ciwxMl0sW2ljLmRheSwxXSxbaWMuZGF5LDJdLFtpYy53ZWVrLDFdLFtpYy5tb250aCwx
XSxbaWMubW9udGgsM10sW2ljLnllYXIsMV1dLFZzPUZzLm11bHRpKFtbIi4lTCIsZnVuY3Rpb24o
bil7cmV0dXJuIG4uZ2V0TWlsbGlzZWNvbmRzKCl9XSxbIjolUyIsZnVuY3Rpb24obil7cmV0dXJu
IG4uZ2V0U2Vjb25kcygpfV0sWyIlSTolTSIsZnVuY3Rpb24obil7cmV0dXJuIG4uZ2V0TWludXRl
cygpfV0sWyIlSSAlcCIsZnVuY3Rpb24obil7cmV0dXJuIG4uZ2V0SG91cnMoKX1dLFsiJWEgJWQi
LGZ1bmN0aW9uKG4pe3JldHVybiBuLmdldERheSgpJiYxIT1uLmdldERhdGUoKX1dLFsiJWIgJWQi
LGZ1bmN0aW9uKG4pe3JldHVybiAxIT1uLmdldERhdGUoKX1dLFsiJUIiLGZ1bmN0aW9uKG4pe3Jl
dHVybiBuLmdldE1vbnRoKCl9XSxbIiVZIixBZV1dKSwkcz17cmFuZ2U6ZnVuY3Rpb24obix0LGUp
e3JldHVybiBHby5yYW5nZShNYXRoLmNlaWwobi9lKSplLCt0LGUpLm1hcChCbyl9LGZsb29yOkF0
LGNlaWw6QXR9O1pzLnllYXI9aWMueWVhcixpYy5zY2FsZT1mdW5jdGlvbigpe3JldHVybiBYbyhH
by5zY2FsZS5saW5lYXIoKSxacyxWcyl9O3ZhciBYcz1acy5tYXAoZnVuY3Rpb24obil7cmV0dXJu
W25bMF0udXRjLG5bMV1dfSksQnM9T3MubXVsdGkoW1siLiVMIixmdW5jdGlvbihuKXtyZXR1cm4g
bi5nZXRVVENNaWxsaXNlY29uZHMoKX1dLFsiOiVTIixmdW5jdGlvbihuKXtyZXR1cm4gbi5nZXRV
VENTZWNvbmRzKCl9XSxbIiVJOiVNIixmdW5jdGlvbihuKXtyZXR1cm4gbi5nZXRVVENNaW51dGVz
KCl9XSxbIiVJICVwIixmdW5jdGlvbihuKXtyZXR1cm4gbi5nZXRVVENIb3VycygpfV0sWyIlYSAl
ZCIsZnVuY3Rpb24obil7cmV0dXJuIG4uZ2V0VVRDRGF5KCkmJjEhPW4uZ2V0VVRDRGF0ZSgpfV0s
WyIlYiAlZCIsZnVuY3Rpb24obil7cmV0dXJuIDEhPW4uZ2V0VVRDRGF0ZSgpfV0sWyIlQiIsZnVu
Y3Rpb24obil7cmV0dXJuIG4uZ2V0VVRDTW9udGgoKX1dLFsiJVkiLEFlXV0pO1hzLnllYXI9aWMu
eWVhci51dGMsaWMuc2NhbGUudXRjPWZ1bmN0aW9uKCl7cmV0dXJuIFhvKEdvLnNjYWxlLmxpbmVh
cigpLFhzLEJzKX0sR28udGV4dD1DdChmdW5jdGlvbihuKXtyZXR1cm4gbi5yZXNwb25zZVRleHR9
KSxHby5qc29uPWZ1bmN0aW9uKG4sdCl7cmV0dXJuIE50KG4sImFwcGxpY2F0aW9uL2pzb24iLEpv
LHQpfSxHby5odG1sPWZ1bmN0aW9uKG4sdCl7cmV0dXJuIE50KG4sInRleHQvaHRtbCIsV28sdCl9
LEdvLnhtbD1DdChmdW5jdGlvbihuKXtyZXR1cm4gbi5yZXNwb25zZVhNTH0pLCJmdW5jdGlvbiI9
PXR5cGVvZiBkZWZpbmUmJmRlZmluZS5hbWQ/ZGVmaW5lKEdvKToib2JqZWN0Ij09dHlwZW9mIG1v
ZHVsZSYmbW9kdWxlLmV4cG9ydHM/bW9kdWxlLmV4cG9ydHM9R286dGhpcy5kMz1Hb30oKTsK"
             )))
  repository)


(defun c/generate-d3-v4-lib (repository)
  "Make available the D3 v4 library for REPOSITORY. This is just to not depend on a network connection."
  (mkdir (format "/tmp/%s/d3/" (f-filename repository)) t)
  (with-temp-file (format "/tmp/%s/d3/d3-v4.min.js" (f-filename repository))
    (insert (base64-decode-string
             "Ly8gaHR0cHM6Ly9kM2pzLm9yZyBWZXJzaW9uIDQuMTMuMC4gQ29weXJpZ2h0IDIwMTggTWlrZSBC
b3N0b2NrLgooZnVuY3Rpb24odCxuKXsib2JqZWN0Ij09dHlwZW9mIGV4cG9ydHMmJiJ1bmRlZmlu
ZWQiIT10eXBlb2YgbW9kdWxlP24oZXhwb3J0cyk6ImZ1bmN0aW9uIj09dHlwZW9mIGRlZmluZSYm
ZGVmaW5lLmFtZD9kZWZpbmUoWyJleHBvcnRzIl0sbik6bih0LmQzPXQuZDN8fHt9KX0pKHRoaXMs
ZnVuY3Rpb24odCl7InVzZSBzdHJpY3QiO2Z1bmN0aW9uIG4odCxuKXtyZXR1cm4gdDxuPy0xOnQ+
bj8xOnQ+PW4/MDpOYU59ZnVuY3Rpb24gZSh0KXtyZXR1cm4gMT09PXQubGVuZ3RoJiYodD1mdW5j
dGlvbih0KXtyZXR1cm4gZnVuY3Rpb24oZSxyKXtyZXR1cm4gbih0KGUpLHIpfX0odCkpLHtsZWZ0
OmZ1bmN0aW9uKG4sZSxyLGkpe2ZvcihudWxsPT1yJiYocj0wKSxudWxsPT1pJiYoaT1uLmxlbmd0
aCk7cjxpOyl7dmFyIG89citpPj4+MTt0KG5bb10sZSk8MD9yPW8rMTppPW99cmV0dXJuIHJ9LHJp
Z2h0OmZ1bmN0aW9uKG4sZSxyLGkpe2ZvcihudWxsPT1yJiYocj0wKSxudWxsPT1pJiYoaT1uLmxl
bmd0aCk7cjxpOyl7dmFyIG89citpPj4+MTt0KG5bb10sZSk+MD9pPW86cj1vKzF9cmV0dXJuIHJ9
fX1mdW5jdGlvbiByKHQsbil7cmV0dXJuW3Qsbl19ZnVuY3Rpb24gaSh0KXtyZXR1cm4gbnVsbD09
PXQ/TmFOOit0fWZ1bmN0aW9uIG8odCxuKXt2YXIgZSxyLG89dC5sZW5ndGgsdT0wLGE9LTEsYz0w
LHM9MDtpZihudWxsPT1uKWZvcig7KythPG87KWlzTmFOKGU9aSh0W2FdKSl8fChzKz0ocj1lLWMp
KihlLShjKz1yLysrdSkpKTtlbHNlIGZvcig7KythPG87KWlzTmFOKGU9aShuKHRbYV0sYSx0KSkp
fHwocys9KHI9ZS1jKSooZS0oYys9ci8rK3UpKSk7aWYodT4xKXJldHVybiBzLyh1LTEpfWZ1bmN0
aW9uIHUodCxuKXt2YXIgZT1vKHQsbik7cmV0dXJuIGU/TWF0aC5zcXJ0KGUpOmV9ZnVuY3Rpb24g
YSh0LG4pe3ZhciBlLHIsaSxvPXQubGVuZ3RoLHU9LTE7aWYobnVsbD09bil7Zm9yKDsrK3U8bzsp
aWYobnVsbCE9KGU9dFt1XSkmJmU+PWUpZm9yKHI9aT1lOysrdTxvOyludWxsIT0oZT10W3VdKSYm
KHI+ZSYmKHI9ZSksaTxlJiYoaT1lKSl9ZWxzZSBmb3IoOysrdTxvOylpZihudWxsIT0oZT1uKHRb
dV0sdSx0KSkmJmU+PWUpZm9yKHI9aT1lOysrdTxvOyludWxsIT0oZT1uKHRbdV0sdSx0KSkmJihy
PmUmJihyPWUpLGk8ZSYmKGk9ZSkpO3JldHVybltyLGldfWZ1bmN0aW9uIGModCl7cmV0dXJuIGZ1
bmN0aW9uKCl7cmV0dXJuIHR9fWZ1bmN0aW9uIHModCl7cmV0dXJuIHR9ZnVuY3Rpb24gZih0LG4s
ZSl7dD0rdCxuPStuLGU9KGk9YXJndW1lbnRzLmxlbmd0aCk8Mj8obj10LHQ9MCwxKTppPDM/MTor
ZTtmb3IodmFyIHI9LTEsaT0wfE1hdGgubWF4KDAsTWF0aC5jZWlsKChuLXQpL2UpKSxvPW5ldyBB
cnJheShpKTsrK3I8aTspb1tyXT10K3IqZTtyZXR1cm4gb31mdW5jdGlvbiBsKHQsbixlKXt2YXIg
cixpLG8sdSxhPS0xO2lmKG49K24sdD0rdCxlPStlLHQ9PT1uJiZlPjApcmV0dXJuW3RdO2lmKChy
PW48dCkmJihpPXQsdD1uLG49aSksMD09PSh1PWgodCxuLGUpKXx8IWlzRmluaXRlKHUpKXJldHVy
bltdO2lmKHU+MClmb3IodD1NYXRoLmNlaWwodC91KSxuPU1hdGguZmxvb3Iobi91KSxvPW5ldyBB
cnJheShpPU1hdGguY2VpbChuLXQrMSkpOysrYTxpOylvW2FdPSh0K2EpKnU7ZWxzZSBmb3IodD1N
YXRoLmZsb29yKHQqdSksbj1NYXRoLmNlaWwobip1KSxvPW5ldyBBcnJheShpPU1hdGguY2VpbCh0
LW4rMSkpOysrYTxpOylvW2FdPSh0LWEpL3U7cmV0dXJuIHImJm8ucmV2ZXJzZSgpLG99ZnVuY3Rp
b24gaCh0LG4sZSl7dmFyIHI9KG4tdCkvTWF0aC5tYXgoMCxlKSxpPU1hdGguZmxvb3IoTWF0aC5s
b2cocikvTWF0aC5MTjEwKSxvPXIvTWF0aC5wb3coMTAsaSk7cmV0dXJuIGk+PTA/KG8+PUhzPzEw
Om8+PWpzPzU6bz49WHM/MjoxKSpNYXRoLnBvdygxMCxpKTotTWF0aC5wb3coMTAsLWkpLyhvPj1I
cz8xMDpvPj1qcz81Om8+PVhzPzI6MSl9ZnVuY3Rpb24gcCh0LG4sZSl7dmFyIHI9TWF0aC5hYnMo
bi10KS9NYXRoLm1heCgwLGUpLGk9TWF0aC5wb3coMTAsTWF0aC5mbG9vcihNYXRoLmxvZyhyKS9N
YXRoLkxOMTApKSxvPXIvaTtyZXR1cm4gbz49SHM/aSo9MTA6bz49anM/aSo9NTpvPj1YcyYmKGkq
PTIpLG48dD8taTppfWZ1bmN0aW9uIGQodCl7cmV0dXJuIE1hdGguY2VpbChNYXRoLmxvZyh0Lmxl
bmd0aCkvTWF0aC5MTjIpKzF9ZnVuY3Rpb24gdih0LG4sZSl7aWYobnVsbD09ZSYmKGU9aSkscj10
Lmxlbmd0aCl7aWYoKG49K24pPD0wfHxyPDIpcmV0dXJuK2UodFswXSwwLHQpO2lmKG4+PTEpcmV0
dXJuK2UodFtyLTFdLHItMSx0KTt2YXIgcixvPShyLTEpKm4sdT1NYXRoLmZsb29yKG8pLGE9K2Uo
dFt1XSx1LHQpO3JldHVybiBhKygrZSh0W3UrMV0sdSsxLHQpLWEpKihvLXUpfX1mdW5jdGlvbiBn
KHQpe2Zvcih2YXIgbixlLHIsaT10Lmxlbmd0aCxvPS0xLHU9MDsrK288aTspdSs9dFtvXS5sZW5n
dGg7Zm9yKGU9bmV3IEFycmF5KHUpOy0taT49MDspZm9yKG49KHI9dFtpXSkubGVuZ3RoOy0tbj49
MDspZVstLXVdPXJbbl07cmV0dXJuIGV9ZnVuY3Rpb24gXyh0LG4pe3ZhciBlLHIsaT10Lmxlbmd0
aCxvPS0xO2lmKG51bGw9PW4pe2Zvcig7KytvPGk7KWlmKG51bGwhPShlPXRbb10pJiZlPj1lKWZv
cihyPWU7KytvPGk7KW51bGwhPShlPXRbb10pJiZyPmUmJihyPWUpfWVsc2UgZm9yKDsrK288aTsp
aWYobnVsbCE9KGU9bih0W29dLG8sdCkpJiZlPj1lKWZvcihyPWU7KytvPGk7KW51bGwhPShlPW4o
dFtvXSxvLHQpKSYmcj5lJiYocj1lKTtyZXR1cm4gcn1mdW5jdGlvbiB5KHQpe2lmKCEoaT10Lmxl
bmd0aCkpcmV0dXJuW107Zm9yKHZhciBuPS0xLGU9Xyh0LG0pLHI9bmV3IEFycmF5KGUpOysrbjxl
Oylmb3IodmFyIGksbz0tMSx1PXJbbl09bmV3IEFycmF5KGkpOysrbzxpOyl1W29dPXRbb11bbl07
cmV0dXJuIHJ9ZnVuY3Rpb24gbSh0KXtyZXR1cm4gdC5sZW5ndGh9ZnVuY3Rpb24geCh0KXtyZXR1
cm4gdH1mdW5jdGlvbiBiKHQpe3JldHVybiJ0cmFuc2xhdGUoIisodCsuNSkrIiwwKSJ9ZnVuY3Rp
b24gdyh0KXtyZXR1cm4idHJhbnNsYXRlKDAsIisodCsuNSkrIikifWZ1bmN0aW9uIE0oKXtyZXR1
cm4hdGhpcy5fX2F4aXN9ZnVuY3Rpb24gVCh0LG4pe2Z1bmN0aW9uIGUoZSl7dmFyIGg9bnVsbD09
aT9uLnRpY2tzP24udGlja3MuYXBwbHkobixyKTpuLmRvbWFpbigpOmkscD1udWxsPT1vP24udGlj
a0Zvcm1hdD9uLnRpY2tGb3JtYXQuYXBwbHkobixyKTp4Om8sZD1NYXRoLm1heCh1LDApK2Msdj1u
LnJhbmdlKCksZz0rdlswXSsuNSxfPSt2W3YubGVuZ3RoLTFdKy41LHk9KG4uYmFuZHdpZHRoP2Z1
bmN0aW9uKHQpe3ZhciBuPU1hdGgubWF4KDAsdC5iYW5kd2lkdGgoKS0xKS8yO3JldHVybiB0LnJv
dW5kKCkmJihuPU1hdGgucm91bmQobikpLGZ1bmN0aW9uKGUpe3JldHVybit0KGUpK259fTpmdW5j
dGlvbih0KXtyZXR1cm4gZnVuY3Rpb24obil7cmV0dXJuK3Qobil9fSkobi5jb3B5KCkpLG09ZS5z
ZWxlY3Rpb24/ZS5zZWxlY3Rpb24oKTplLGI9bS5zZWxlY3RBbGwoIi5kb21haW4iKS5kYXRhKFtu
dWxsXSksdz1tLnNlbGVjdEFsbCgiLnRpY2siKS5kYXRhKGgsbikub3JkZXIoKSxUPXcuZXhpdCgp
LE49dy5lbnRlcigpLmFwcGVuZCgiZyIpLmF0dHIoImNsYXNzIiwidGljayIpLGs9dy5zZWxlY3Qo
ImxpbmUiKSxTPXcuc2VsZWN0KCJ0ZXh0Iik7Yj1iLm1lcmdlKGIuZW50ZXIoKS5pbnNlcnQoInBh
dGgiLCIudGljayIpLmF0dHIoImNsYXNzIiwiZG9tYWluIikuYXR0cigic3Ryb2tlIiwiIzAwMCIp
KSx3PXcubWVyZ2UoTiksaz1rLm1lcmdlKE4uYXBwZW5kKCJsaW5lIikuYXR0cigic3Ryb2tlIiwi
IzAwMCIpLmF0dHIoZisiMiIscyp1KSksUz1TLm1lcmdlKE4uYXBwZW5kKCJ0ZXh0IikuYXR0cigi
ZmlsbCIsIiMwMDAiKS5hdHRyKGYscypkKS5hdHRyKCJkeSIsdD09PSRzPyIwZW0iOnQ9PT1acz8i
MC43MWVtIjoiMC4zMmVtIikpLGUhPT1tJiYoYj1iLnRyYW5zaXRpb24oZSksdz13LnRyYW5zaXRp
b24oZSksaz1rLnRyYW5zaXRpb24oZSksUz1TLnRyYW5zaXRpb24oZSksVD1ULnRyYW5zaXRpb24o
ZSkuYXR0cigib3BhY2l0eSIsUXMpLmF0dHIoInRyYW5zZm9ybSIsZnVuY3Rpb24odCl7cmV0dXJu
IGlzRmluaXRlKHQ9eSh0KSk/bCh0KTp0aGlzLmdldEF0dHJpYnV0ZSgidHJhbnNmb3JtIil9KSxO
LmF0dHIoIm9wYWNpdHkiLFFzKS5hdHRyKCJ0cmFuc2Zvcm0iLGZ1bmN0aW9uKHQpe3ZhciBuPXRo
aXMucGFyZW50Tm9kZS5fX2F4aXM7cmV0dXJuIGwobiYmaXNGaW5pdGUobj1uKHQpKT9uOnkodCkp
fSkpLFQucmVtb3ZlKCksYi5hdHRyKCJkIix0PT09R3N8fHQ9PVdzPyJNIitzKmErIiwiK2crIkgw
LjVWIitfKyJIIitzKmE6Ik0iK2crIiwiK3MqYSsiVjAuNUgiK18rIlYiK3MqYSksdy5hdHRyKCJv
cGFjaXR5IiwxKS5hdHRyKCJ0cmFuc2Zvcm0iLGZ1bmN0aW9uKHQpe3JldHVybiBsKHkodCkpfSks
ay5hdHRyKGYrIjIiLHMqdSksUy5hdHRyKGYscypkKS50ZXh0KHApLG0uZmlsdGVyKE0pLmF0dHIo
ImZpbGwiLCJub25lIikuYXR0cigiZm9udC1zaXplIiwxMCkuYXR0cigiZm9udC1mYW1pbHkiLCJz
YW5zLXNlcmlmIikuYXR0cigidGV4dC1hbmNob3IiLHQ9PT1Xcz8ic3RhcnQiOnQ9PT1Hcz8iZW5k
IjoibWlkZGxlIiksbS5lYWNoKGZ1bmN0aW9uKCl7dGhpcy5fX2F4aXM9eX0pfXZhciByPVtdLGk9
bnVsbCxvPW51bGwsdT02LGE9NixjPTMscz10PT09JHN8fHQ9PT1Hcz8tMToxLGY9dD09PUdzfHx0
PT09V3M/IngiOiJ5IixsPXQ9PT0kc3x8dD09PVpzP2I6dztyZXR1cm4gZS5zY2FsZT1mdW5jdGlv
bih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8obj10LGUpOm59LGUudGlja3M9ZnVuY3Rpb24o
KXtyZXR1cm4gcj1Wcy5jYWxsKGFyZ3VtZW50cyksZX0sZS50aWNrQXJndW1lbnRzPWZ1bmN0aW9u
KHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhyPW51bGw9PXQ/W106VnMuY2FsbCh0KSxlKTpy
LnNsaWNlKCl9LGUudGlja1ZhbHVlcz1mdW5jdGlvbih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0
aD8oaT1udWxsPT10P251bGw6VnMuY2FsbCh0KSxlKTppJiZpLnNsaWNlKCl9LGUudGlja0Zvcm1h
dD1mdW5jdGlvbih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8obz10LGUpOm99LGUudGlja1Np
emU9ZnVuY3Rpb24odCl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KHU9YT0rdCxlKTp1fSxlLnRp
Y2tTaXplSW5uZXI9ZnVuY3Rpb24odCl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KHU9K3QsZSk6
dX0sZS50aWNrU2l6ZU91dGVyPWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhh
PSt0LGUpOmF9LGUudGlja1BhZGRpbmc9ZnVuY3Rpb24odCl7cmV0dXJuIGFyZ3VtZW50cy5sZW5n
dGg/KGM9K3QsZSk6Y30sZX1mdW5jdGlvbiBOKCl7Zm9yKHZhciB0LG49MCxlPWFyZ3VtZW50cy5s
ZW5ndGgscj17fTtuPGU7KytuKXtpZighKHQ9YXJndW1lbnRzW25dKyIiKXx8dCBpbiByKXRocm93
IG5ldyBFcnJvcigiaWxsZWdhbCB0eXBlOiAiK3QpO3JbdF09W119cmV0dXJuIG5ldyBrKHIpfWZ1
bmN0aW9uIGsodCl7dGhpcy5fPXR9ZnVuY3Rpb24gUyh0LG4sZSl7Zm9yKHZhciByPTAsaT10Lmxl
bmd0aDtyPGk7KytyKWlmKHRbcl0ubmFtZT09PW4pe3Rbcl09SnMsdD10LnNsaWNlKDAscikuY29u
Y2F0KHQuc2xpY2UocisxKSk7YnJlYWt9cmV0dXJuIG51bGwhPWUmJnQucHVzaCh7bmFtZTpuLHZh
bHVlOmV9KSx0fWZ1bmN0aW9uIEUodCl7dmFyIG49dCs9IiIsZT1uLmluZGV4T2YoIjoiKTtyZXR1
cm4gZT49MCYmInhtbG5zIiE9PShuPXQuc2xpY2UoMCxlKSkmJih0PXQuc2xpY2UoZSsxKSksdGYu
aGFzT3duUHJvcGVydHkobik/e3NwYWNlOnRmW25dLGxvY2FsOnR9OnR9ZnVuY3Rpb24gQSh0KXt2
YXIgbj1FKHQpO3JldHVybihuLmxvY2FsP2Z1bmN0aW9uKHQpe3JldHVybiBmdW5jdGlvbigpe3Jl
dHVybiB0aGlzLm93bmVyRG9jdW1lbnQuY3JlYXRlRWxlbWVudE5TKHQuc3BhY2UsdC5sb2NhbCl9
fTpmdW5jdGlvbih0KXtyZXR1cm4gZnVuY3Rpb24oKXt2YXIgbj10aGlzLm93bmVyRG9jdW1lbnQs
ZT10aGlzLm5hbWVzcGFjZVVSSTtyZXR1cm4gZT09PUtzJiZuLmRvY3VtZW50RWxlbWVudC5uYW1l
c3BhY2VVUkk9PT1Lcz9uLmNyZWF0ZUVsZW1lbnQodCk6bi5jcmVhdGVFbGVtZW50TlMoZSx0KX19
KShuKX1mdW5jdGlvbiBDKCl7fWZ1bmN0aW9uIHoodCl7cmV0dXJuIG51bGw9PXQ/QzpmdW5jdGlv
bigpe3JldHVybiB0aGlzLnF1ZXJ5U2VsZWN0b3IodCl9fWZ1bmN0aW9uIFAoKXtyZXR1cm5bXX1m
dW5jdGlvbiBSKHQpe3JldHVybiBudWxsPT10P1A6ZnVuY3Rpb24oKXtyZXR1cm4gdGhpcy5xdWVy
eVNlbGVjdG9yQWxsKHQpfX1mdW5jdGlvbiBMKHQpe3JldHVybiBuZXcgQXJyYXkodC5sZW5ndGgp
fWZ1bmN0aW9uIHEodCxuKXt0aGlzLm93bmVyRG9jdW1lbnQ9dC5vd25lckRvY3VtZW50LHRoaXMu
bmFtZXNwYWNlVVJJPXQubmFtZXNwYWNlVVJJLHRoaXMuX25leHQ9bnVsbCx0aGlzLl9wYXJlbnQ9
dCx0aGlzLl9fZGF0YV9fPW59ZnVuY3Rpb24gRCh0LG4sZSxyLGksbyl7Zm9yKHZhciB1LGE9MCxj
PW4ubGVuZ3RoLHM9by5sZW5ndGg7YTxzOysrYSkodT1uW2FdKT8odS5fX2RhdGFfXz1vW2FdLHJb
YV09dSk6ZVthXT1uZXcgcSh0LG9bYV0pO2Zvcig7YTxjOysrYSkodT1uW2FdKSYmKGlbYV09dSl9
ZnVuY3Rpb24gVSh0LG4sZSxyLGksbyx1KXt2YXIgYSxjLHMsZj17fSxsPW4ubGVuZ3RoLGg9by5s
ZW5ndGgscD1uZXcgQXJyYXkobCk7Zm9yKGE9MDthPGw7KythKShjPW5bYV0pJiYocFthXT1zPXVm
K3UuY2FsbChjLGMuX19kYXRhX18sYSxuKSxzIGluIGY/aVthXT1jOmZbc109Yyk7Zm9yKGE9MDth
PGg7KythKShjPWZbcz11Zit1LmNhbGwodCxvW2FdLGEsbyldKT8oclthXT1jLGMuX19kYXRhX189
b1thXSxmW3NdPW51bGwpOmVbYV09bmV3IHEodCxvW2FdKTtmb3IoYT0wO2E8bDsrK2EpKGM9blth
XSkmJmZbcFthXV09PT1jJiYoaVthXT1jKX1mdW5jdGlvbiBPKHQsbil7cmV0dXJuIHQ8bj8tMTp0
Pm4/MTp0Pj1uPzA6TmFOfWZ1bmN0aW9uIEYodCl7cmV0dXJuIHQub3duZXJEb2N1bWVudCYmdC5v
d25lckRvY3VtZW50LmRlZmF1bHRWaWV3fHx0LmRvY3VtZW50JiZ0fHx0LmRlZmF1bHRWaWV3fWZ1
bmN0aW9uIEkodCxuKXtyZXR1cm4gdC5zdHlsZS5nZXRQcm9wZXJ0eVZhbHVlKG4pfHxGKHQpLmdl
dENvbXB1dGVkU3R5bGUodCxudWxsKS5nZXRQcm9wZXJ0eVZhbHVlKG4pfWZ1bmN0aW9uIFkodCl7
cmV0dXJuIHQudHJpbSgpLnNwbGl0KC9efFxzKy8pfWZ1bmN0aW9uIEIodCl7cmV0dXJuIHQuY2xh
c3NMaXN0fHxuZXcgSCh0KX1mdW5jdGlvbiBIKHQpe3RoaXMuX25vZGU9dCx0aGlzLl9uYW1lcz1Z
KHQuZ2V0QXR0cmlidXRlKCJjbGFzcyIpfHwiIil9ZnVuY3Rpb24gaih0LG4pe2Zvcih2YXIgZT1C
KHQpLHI9LTEsaT1uLmxlbmd0aDsrK3I8aTspZS5hZGQobltyXSl9ZnVuY3Rpb24gWCh0LG4pe2Zv
cih2YXIgZT1CKHQpLHI9LTEsaT1uLmxlbmd0aDsrK3I8aTspZS5yZW1vdmUobltyXSl9ZnVuY3Rp
b24gVigpe3RoaXMudGV4dENvbnRlbnQ9IiJ9ZnVuY3Rpb24gJCgpe3RoaXMuaW5uZXJIVE1MPSIi
fWZ1bmN0aW9uIFcoKXt0aGlzLm5leHRTaWJsaW5nJiZ0aGlzLnBhcmVudE5vZGUuYXBwZW5kQ2hp
bGQodGhpcyl9ZnVuY3Rpb24gWigpe3RoaXMucHJldmlvdXNTaWJsaW5nJiZ0aGlzLnBhcmVudE5v
ZGUuaW5zZXJ0QmVmb3JlKHRoaXMsdGhpcy5wYXJlbnROb2RlLmZpcnN0Q2hpbGQpfWZ1bmN0aW9u
IEcoKXtyZXR1cm4gbnVsbH1mdW5jdGlvbiBRKCl7dmFyIHQ9dGhpcy5wYXJlbnROb2RlO3QmJnQu
cmVtb3ZlQ2hpbGQodGhpcyl9ZnVuY3Rpb24gSigpe3JldHVybiB0aGlzLnBhcmVudE5vZGUuaW5z
ZXJ0QmVmb3JlKHRoaXMuY2xvbmVOb2RlKCExKSx0aGlzLm5leHRTaWJsaW5nKX1mdW5jdGlvbiBL
KCl7cmV0dXJuIHRoaXMucGFyZW50Tm9kZS5pbnNlcnRCZWZvcmUodGhpcy5jbG9uZU5vZGUoITAp
LHRoaXMubmV4dFNpYmxpbmcpfWZ1bmN0aW9uIHR0KHQsbixlKXtyZXR1cm4gdD1udCh0LG4sZSks
ZnVuY3Rpb24obil7dmFyIGU9bi5yZWxhdGVkVGFyZ2V0O2UmJihlPT09dGhpc3x8OCZlLmNvbXBh
cmVEb2N1bWVudFBvc2l0aW9uKHRoaXMpKXx8dC5jYWxsKHRoaXMsbil9fWZ1bmN0aW9uIG50KG4s
ZSxyKXtyZXR1cm4gZnVuY3Rpb24oaSl7dmFyIG89dC5ldmVudDt0LmV2ZW50PWk7dHJ5e24uY2Fs
bCh0aGlzLHRoaXMuX19kYXRhX18sZSxyKX1maW5hbGx5e3QuZXZlbnQ9b319fWZ1bmN0aW9uIGV0
KHQpe3JldHVybiBmdW5jdGlvbigpe3ZhciBuPXRoaXMuX19vbjtpZihuKXtmb3IodmFyIGUscj0w
LGk9LTEsbz1uLmxlbmd0aDtyPG87KytyKWU9bltyXSx0LnR5cGUmJmUudHlwZSE9PXQudHlwZXx8
ZS5uYW1lIT09dC5uYW1lP25bKytpXT1lOnRoaXMucmVtb3ZlRXZlbnRMaXN0ZW5lcihlLnR5cGUs
ZS5saXN0ZW5lcixlLmNhcHR1cmUpOysraT9uLmxlbmd0aD1pOmRlbGV0ZSB0aGlzLl9fb259fX1m
dW5jdGlvbiBydCh0LG4sZSl7dmFyIHI9YWYuaGFzT3duUHJvcGVydHkodC50eXBlKT90dDpudDty
ZXR1cm4gZnVuY3Rpb24oaSxvLHUpe3ZhciBhLGM9dGhpcy5fX29uLHM9cihuLG8sdSk7aWYoYylm
b3IodmFyIGY9MCxsPWMubGVuZ3RoO2Y8bDsrK2YpaWYoKGE9Y1tmXSkudHlwZT09PXQudHlwZSYm
YS5uYW1lPT09dC5uYW1lKXJldHVybiB0aGlzLnJlbW92ZUV2ZW50TGlzdGVuZXIoYS50eXBlLGEu
bGlzdGVuZXIsYS5jYXB0dXJlKSx0aGlzLmFkZEV2ZW50TGlzdGVuZXIoYS50eXBlLGEubGlzdGVu
ZXI9cyxhLmNhcHR1cmU9ZSksdm9pZChhLnZhbHVlPW4pO3RoaXMuYWRkRXZlbnRMaXN0ZW5lcih0
LnR5cGUscyxlKSxhPXt0eXBlOnQudHlwZSxuYW1lOnQubmFtZSx2YWx1ZTpuLGxpc3RlbmVyOnMs
Y2FwdHVyZTplfSxjP2MucHVzaChhKTp0aGlzLl9fb249W2FdfX1mdW5jdGlvbiBpdChuLGUscixp
KXt2YXIgbz10LmV2ZW50O24uc291cmNlRXZlbnQ9dC5ldmVudCx0LmV2ZW50PW47dHJ5e3JldHVy
biBlLmFwcGx5KHIsaSl9ZmluYWxseXt0LmV2ZW50PW99fWZ1bmN0aW9uIG90KHQsbixlKXt2YXIg
cj1GKHQpLGk9ci5DdXN0b21FdmVudDsiZnVuY3Rpb24iPT10eXBlb2YgaT9pPW5ldyBpKG4sZSk6
KGk9ci5kb2N1bWVudC5jcmVhdGVFdmVudCgiRXZlbnQiKSxlPyhpLmluaXRFdmVudChuLGUuYnVi
YmxlcyxlLmNhbmNlbGFibGUpLGkuZGV0YWlsPWUuZGV0YWlsKTppLmluaXRFdmVudChuLCExLCEx
KSksdC5kaXNwYXRjaEV2ZW50KGkpfWZ1bmN0aW9uIHV0KHQsbil7dGhpcy5fZ3JvdXBzPXQsdGhp
cy5fcGFyZW50cz1ufWZ1bmN0aW9uIGF0KCl7cmV0dXJuIG5ldyB1dChbW2RvY3VtZW50LmRvY3Vt
ZW50RWxlbWVudF1dLGNmKX1mdW5jdGlvbiBjdCh0KXtyZXR1cm4ic3RyaW5nIj09dHlwZW9mIHQ/
bmV3IHV0KFtbZG9jdW1lbnQucXVlcnlTZWxlY3Rvcih0KV1dLFtkb2N1bWVudC5kb2N1bWVudEVs
ZW1lbnRdKTpuZXcgdXQoW1t0XV0sY2YpfWZ1bmN0aW9uIHN0KCl7cmV0dXJuIG5ldyBmdH1mdW5j
dGlvbiBmdCgpe3RoaXMuXz0iQCIrKCsrc2YpLnRvU3RyaW5nKDM2KX1mdW5jdGlvbiBsdCgpe2Zv
cih2YXIgbixlPXQuZXZlbnQ7bj1lLnNvdXJjZUV2ZW50OyllPW47cmV0dXJuIGV9ZnVuY3Rpb24g
aHQodCxuKXt2YXIgZT10Lm93bmVyU1ZHRWxlbWVudHx8dDtpZihlLmNyZWF0ZVNWR1BvaW50KXt2
YXIgcj1lLmNyZWF0ZVNWR1BvaW50KCk7cmV0dXJuIHIueD1uLmNsaWVudFgsci55PW4uY2xpZW50
WSxyPXIubWF0cml4VHJhbnNmb3JtKHQuZ2V0U2NyZWVuQ1RNKCkuaW52ZXJzZSgpKSxbci54LHIu
eV19dmFyIGk9dC5nZXRCb3VuZGluZ0NsaWVudFJlY3QoKTtyZXR1cm5bbi5jbGllbnRYLWkubGVm
dC10LmNsaWVudExlZnQsbi5jbGllbnRZLWkudG9wLXQuY2xpZW50VG9wXX1mdW5jdGlvbiBwdCh0
KXt2YXIgbj1sdCgpO3JldHVybiBuLmNoYW5nZWRUb3VjaGVzJiYobj1uLmNoYW5nZWRUb3VjaGVz
WzBdKSxodCh0LG4pfWZ1bmN0aW9uIGR0KHQsbixlKXthcmd1bWVudHMubGVuZ3RoPDMmJihlPW4s
bj1sdCgpLmNoYW5nZWRUb3VjaGVzKTtmb3IodmFyIHIsaT0wLG89bj9uLmxlbmd0aDowO2k8bzsr
K2kpaWYoKHI9bltpXSkuaWRlbnRpZmllcj09PWUpcmV0dXJuIGh0KHQscik7cmV0dXJuIG51bGx9
ZnVuY3Rpb24gdnQoKXt0LmV2ZW50LnN0b3BJbW1lZGlhdGVQcm9wYWdhdGlvbigpfWZ1bmN0aW9u
IGd0KCl7dC5ldmVudC5wcmV2ZW50RGVmYXVsdCgpLHQuZXZlbnQuc3RvcEltbWVkaWF0ZVByb3Bh
Z2F0aW9uKCl9ZnVuY3Rpb24gX3QodCl7dmFyIG49dC5kb2N1bWVudC5kb2N1bWVudEVsZW1lbnQs
ZT1jdCh0KS5vbigiZHJhZ3N0YXJ0LmRyYWciLGd0LCEwKTsib25zZWxlY3RzdGFydCJpbiBuP2Uu
b24oInNlbGVjdHN0YXJ0LmRyYWciLGd0LCEwKToobi5fX25vc2VsZWN0PW4uc3R5bGUuTW96VXNl
clNlbGVjdCxuLnN0eWxlLk1velVzZXJTZWxlY3Q9Im5vbmUiKX1mdW5jdGlvbiB5dCh0LG4pe3Zh
ciBlPXQuZG9jdW1lbnQuZG9jdW1lbnRFbGVtZW50LHI9Y3QodCkub24oImRyYWdzdGFydC5kcmFn
IixudWxsKTtuJiYoci5vbigiY2xpY2suZHJhZyIsZ3QsITApLHNldFRpbWVvdXQoZnVuY3Rpb24o
KXtyLm9uKCJjbGljay5kcmFnIixudWxsKX0sMCkpLCJvbnNlbGVjdHN0YXJ0ImluIGU/ci5vbigi
c2VsZWN0c3RhcnQuZHJhZyIsbnVsbCk6KGUuc3R5bGUuTW96VXNlclNlbGVjdD1lLl9fbm9zZWxl
Y3QsZGVsZXRlIGUuX19ub3NlbGVjdCl9ZnVuY3Rpb24gbXQodCl7cmV0dXJuIGZ1bmN0aW9uKCl7
cmV0dXJuIHR9fWZ1bmN0aW9uIHh0KHQsbixlLHIsaSxvLHUsYSxjLHMpe3RoaXMudGFyZ2V0PXQs
dGhpcy50eXBlPW4sdGhpcy5zdWJqZWN0PWUsdGhpcy5pZGVudGlmaWVyPXIsdGhpcy5hY3RpdmU9
aSx0aGlzLng9byx0aGlzLnk9dSx0aGlzLmR4PWEsdGhpcy5keT1jLHRoaXMuXz1zfWZ1bmN0aW9u
IGJ0KCl7cmV0dXJuIXQuZXZlbnQuYnV0dG9ufWZ1bmN0aW9uIHd0KCl7cmV0dXJuIHRoaXMucGFy
ZW50Tm9kZX1mdW5jdGlvbiBNdChuKXtyZXR1cm4gbnVsbD09bj97eDp0LmV2ZW50LngseTp0LmV2
ZW50Lnl9Om59ZnVuY3Rpb24gVHQoKXtyZXR1cm4ib250b3VjaHN0YXJ0ImluIHRoaXN9ZnVuY3Rp
b24gTnQodCxuLGUpe3QucHJvdG90eXBlPW4ucHJvdG90eXBlPWUsZS5jb25zdHJ1Y3Rvcj10fWZ1
bmN0aW9uIGt0KHQsbil7dmFyIGU9T2JqZWN0LmNyZWF0ZSh0LnByb3RvdHlwZSk7Zm9yKHZhciBy
IGluIG4pZVtyXT1uW3JdO3JldHVybiBlfWZ1bmN0aW9uIFN0KCl7fWZ1bmN0aW9uIEV0KHQpe3Zh
ciBuO3JldHVybiB0PSh0KyIiKS50cmltKCkudG9Mb3dlckNhc2UoKSwobj1wZi5leGVjKHQpKT8o
bj1wYXJzZUludChuWzFdLDE2KSxuZXcgUnQobj4+OCYxNXxuPj40JjI0MCxuPj40JjE1fDI0MCZu
LCgxNSZuKTw8NHwxNSZuLDEpKToobj1kZi5leGVjKHQpKT9BdChwYXJzZUludChuWzFdLDE2KSk6
KG49dmYuZXhlYyh0KSk/bmV3IFJ0KG5bMV0sblsyXSxuWzNdLDEpOihuPWdmLmV4ZWModCkpP25l
dyBSdCgyNTUqblsxXS8xMDAsMjU1Km5bMl0vMTAwLDI1NSpuWzNdLzEwMCwxKToobj1fZi5leGVj
KHQpKT9DdChuWzFdLG5bMl0sblszXSxuWzRdKToobj15Zi5leGVjKHQpKT9DdCgyNTUqblsxXS8x
MDAsMjU1Km5bMl0vMTAwLDI1NSpuWzNdLzEwMCxuWzRdKToobj1tZi5leGVjKHQpKT9MdChuWzFd
LG5bMl0vMTAwLG5bM10vMTAwLDEpOihuPXhmLmV4ZWModCkpP0x0KG5bMV0sblsyXS8xMDAsblsz
XS8xMDAsbls0XSk6YmYuaGFzT3duUHJvcGVydHkodCk/QXQoYmZbdF0pOiJ0cmFuc3BhcmVudCI9
PT10P25ldyBSdChOYU4sTmFOLE5hTiwwKTpudWxsfWZ1bmN0aW9uIEF0KHQpe3JldHVybiBuZXcg
UnQodD4+MTYmMjU1LHQ+PjgmMjU1LDI1NSZ0LDEpfWZ1bmN0aW9uIEN0KHQsbixlLHIpe3JldHVy
biByPD0wJiYodD1uPWU9TmFOKSxuZXcgUnQodCxuLGUscil9ZnVuY3Rpb24genQodCl7cmV0dXJu
IHQgaW5zdGFuY2VvZiBTdHx8KHQ9RXQodCkpLHQ/KHQ9dC5yZ2IoKSxuZXcgUnQodC5yLHQuZyx0
LmIsdC5vcGFjaXR5KSk6bmV3IFJ0fWZ1bmN0aW9uIFB0KHQsbixlLHIpe3JldHVybiAxPT09YXJn
dW1lbnRzLmxlbmd0aD96dCh0KTpuZXcgUnQodCxuLGUsbnVsbD09cj8xOnIpfWZ1bmN0aW9uIFJ0
KHQsbixlLHIpe3RoaXMucj0rdCx0aGlzLmc9K24sdGhpcy5iPStlLHRoaXMub3BhY2l0eT0rcn1m
dW5jdGlvbiBMdCh0LG4sZSxyKXtyZXR1cm4gcjw9MD90PW49ZT1OYU46ZTw9MHx8ZT49MT90PW49
TmFOOm48PTAmJih0PU5hTiksbmV3IER0KHQsbixlLHIpfWZ1bmN0aW9uIHF0KHQsbixlLHIpe3Jl
dHVybiAxPT09YXJndW1lbnRzLmxlbmd0aD9mdW5jdGlvbih0KXtpZih0IGluc3RhbmNlb2YgRHQp
cmV0dXJuIG5ldyBEdCh0LmgsdC5zLHQubCx0Lm9wYWNpdHkpO2lmKHQgaW5zdGFuY2VvZiBTdHx8
KHQ9RXQodCkpLCF0KXJldHVybiBuZXcgRHQ7aWYodCBpbnN0YW5jZW9mIER0KXJldHVybiB0O3Zh
ciBuPSh0PXQucmdiKCkpLnIvMjU1LGU9dC5nLzI1NSxyPXQuYi8yNTUsaT1NYXRoLm1pbihuLGUs
ciksbz1NYXRoLm1heChuLGUsciksdT1OYU4sYT1vLWksYz0obytpKS8yO3JldHVybiBhPyh1PW49
PT1vPyhlLXIpL2ErNiooZTxyKTplPT09bz8oci1uKS9hKzI6KG4tZSkvYSs0LGEvPWM8LjU/bytp
OjItby1pLHUqPTYwKTphPWM+MCYmYzwxPzA6dSxuZXcgRHQodSxhLGMsdC5vcGFjaXR5KX0odCk6
bmV3IER0KHQsbixlLG51bGw9PXI/MTpyKX1mdW5jdGlvbiBEdCh0LG4sZSxyKXt0aGlzLmg9K3Qs
dGhpcy5zPStuLHRoaXMubD0rZSx0aGlzLm9wYWNpdHk9K3J9ZnVuY3Rpb24gVXQodCxuLGUpe3Jl
dHVybiAyNTUqKHQ8NjA/bisoZS1uKSp0LzYwOnQ8MTgwP2U6dDwyNDA/bisoZS1uKSooMjQwLXQp
LzYwOm4pfWZ1bmN0aW9uIE90KHQpe2lmKHQgaW5zdGFuY2VvZiBJdClyZXR1cm4gbmV3IEl0KHQu
bCx0LmEsdC5iLHQub3BhY2l0eSk7aWYodCBpbnN0YW5jZW9mIFZ0KXt2YXIgbj10Lmgqd2Y7cmV0
dXJuIG5ldyBJdCh0LmwsTWF0aC5jb3MobikqdC5jLE1hdGguc2luKG4pKnQuYyx0Lm9wYWNpdHkp
fXQgaW5zdGFuY2VvZiBSdHx8KHQ9enQodCkpO3ZhciBlPWp0KHQucikscj1qdCh0LmcpLGk9anQo
dC5iKSxvPVl0KCguNDEyNDU2NCplKy4zNTc1NzYxKnIrLjE4MDQzNzUqaSkvVGYpLHU9WXQoKC4y
MTI2NzI5KmUrLjcxNTE1MjIqcisuMDcyMTc1KmkpL05mKTtyZXR1cm4gbmV3IEl0KDExNip1LTE2
LDUwMCooby11KSwyMDAqKHUtWXQoKC4wMTkzMzM5KmUrLjExOTE5MipyKy45NTAzMDQxKmkpL2tm
KSksdC5vcGFjaXR5KX1mdW5jdGlvbiBGdCh0LG4sZSxyKXtyZXR1cm4gMT09PWFyZ3VtZW50cy5s
ZW5ndGg/T3QodCk6bmV3IEl0KHQsbixlLG51bGw9PXI/MTpyKX1mdW5jdGlvbiBJdCh0LG4sZSxy
KXt0aGlzLmw9K3QsdGhpcy5hPStuLHRoaXMuYj0rZSx0aGlzLm9wYWNpdHk9K3J9ZnVuY3Rpb24g
WXQodCl7cmV0dXJuIHQ+Q2Y/TWF0aC5wb3codCwxLzMpOnQvQWYrU2Z9ZnVuY3Rpb24gQnQodCl7
cmV0dXJuIHQ+RWY/dCp0KnQ6QWYqKHQtU2YpfWZ1bmN0aW9uIEh0KHQpe3JldHVybiAyNTUqKHQ8
PS4wMDMxMzA4PzEyLjkyKnQ6MS4wNTUqTWF0aC5wb3codCwxLzIuNCktLjA1NSl9ZnVuY3Rpb24g
anQodCl7cmV0dXJuKHQvPTI1NSk8PS4wNDA0NT90LzEyLjkyOk1hdGgucG93KCh0Ky4wNTUpLzEu
MDU1LDIuNCl9ZnVuY3Rpb24gWHQodCxuLGUscil7cmV0dXJuIDE9PT1hcmd1bWVudHMubGVuZ3Ro
P2Z1bmN0aW9uKHQpe2lmKHQgaW5zdGFuY2VvZiBWdClyZXR1cm4gbmV3IFZ0KHQuaCx0LmMsdC5s
LHQub3BhY2l0eSk7dCBpbnN0YW5jZW9mIEl0fHwodD1PdCh0KSk7dmFyIG49TWF0aC5hdGFuMih0
LmIsdC5hKSpNZjtyZXR1cm4gbmV3IFZ0KG48MD9uKzM2MDpuLE1hdGguc3FydCh0LmEqdC5hK3Qu
Yip0LmIpLHQubCx0Lm9wYWNpdHkpfSh0KTpuZXcgVnQodCxuLGUsbnVsbD09cj8xOnIpfWZ1bmN0
aW9uIFZ0KHQsbixlLHIpe3RoaXMuaD0rdCx0aGlzLmM9K24sdGhpcy5sPStlLHRoaXMub3BhY2l0
eT0rcn1mdW5jdGlvbiAkdCh0LG4sZSxyKXtyZXR1cm4gMT09PWFyZ3VtZW50cy5sZW5ndGg/ZnVu
Y3Rpb24odCl7aWYodCBpbnN0YW5jZW9mIFd0KXJldHVybiBuZXcgV3QodC5oLHQucyx0LmwsdC5v
cGFjaXR5KTt0IGluc3RhbmNlb2YgUnR8fCh0PXp0KHQpKTt2YXIgbj10LnIvMjU1LGU9dC5nLzI1
NSxyPXQuYi8yNTUsaT0oRGYqcitMZipuLXFmKmUpLyhEZitMZi1xZiksbz1yLWksdT0oUmYqKGUt
aSktemYqbykvUGYsYT1NYXRoLnNxcnQodSp1K28qbykvKFJmKmkqKDEtaSkpLGM9YT9NYXRoLmF0
YW4yKHUsbykqTWYtMTIwOk5hTjtyZXR1cm4gbmV3IFd0KGM8MD9jKzM2MDpjLGEsaSx0Lm9wYWNp
dHkpfSh0KTpuZXcgV3QodCxuLGUsbnVsbD09cj8xOnIpfWZ1bmN0aW9uIFd0KHQsbixlLHIpe3Ro
aXMuaD0rdCx0aGlzLnM9K24sdGhpcy5sPStlLHRoaXMub3BhY2l0eT0rcn1mdW5jdGlvbiBadCh0
LG4sZSxyLGkpe3ZhciBvPXQqdCx1PW8qdDtyZXR1cm4oKDEtMyp0KzMqby11KSpuKyg0LTYqbysz
KnUpKmUrKDErMyp0KzMqby0zKnUpKnIrdSppKS82fWZ1bmN0aW9uIEd0KHQpe3ZhciBuPXQubGVu
Z3RoLTE7cmV0dXJuIGZ1bmN0aW9uKGUpe3ZhciByPWU8PTA/ZT0wOmU+PTE/KGU9MSxuLTEpOk1h
dGguZmxvb3IoZSpuKSxpPXRbcl0sbz10W3IrMV0sdT1yPjA/dFtyLTFdOjIqaS1vLGE9cjxuLTE/
dFtyKzJdOjIqby1pO3JldHVybiBadCgoZS1yL24pKm4sdSxpLG8sYSl9fWZ1bmN0aW9uIFF0KHQp
e3ZhciBuPXQubGVuZ3RoO3JldHVybiBmdW5jdGlvbihlKXt2YXIgcj1NYXRoLmZsb29yKCgoZSU9
MSk8MD8rK2U6ZSkqbiksaT10WyhyK24tMSklbl0sbz10W3Ilbl0sdT10WyhyKzEpJW5dLGE9dFso
cisyKSVuXTtyZXR1cm4gWnQoKGUtci9uKSpuLGksbyx1LGEpfX1mdW5jdGlvbiBKdCh0KXtyZXR1
cm4gZnVuY3Rpb24oKXtyZXR1cm4gdH19ZnVuY3Rpb24gS3QodCxuKXtyZXR1cm4gZnVuY3Rpb24o
ZSl7cmV0dXJuIHQrZSpufX1mdW5jdGlvbiB0bih0LG4pe3ZhciBlPW4tdDtyZXR1cm4gZT9LdCh0
LGU+MTgwfHxlPC0xODA/ZS0zNjAqTWF0aC5yb3VuZChlLzM2MCk6ZSk6SnQoaXNOYU4odCk/bjp0
KX1mdW5jdGlvbiBubih0KXtyZXR1cm4gMT09KHQ9K3QpP2VuOmZ1bmN0aW9uKG4sZSl7cmV0dXJu
IGUtbj9mdW5jdGlvbih0LG4sZSl7cmV0dXJuIHQ9TWF0aC5wb3codCxlKSxuPU1hdGgucG93KG4s
ZSktdCxlPTEvZSxmdW5jdGlvbihyKXtyZXR1cm4gTWF0aC5wb3codCtyKm4sZSl9fShuLGUsdCk6
SnQoaXNOYU4obik/ZTpuKX19ZnVuY3Rpb24gZW4odCxuKXt2YXIgZT1uLXQ7cmV0dXJuIGU/S3Qo
dCxlKTpKdChpc05hTih0KT9uOnQpfWZ1bmN0aW9uIHJuKHQpe3JldHVybiBmdW5jdGlvbihuKXt2
YXIgZSxyLGk9bi5sZW5ndGgsbz1uZXcgQXJyYXkoaSksdT1uZXcgQXJyYXkoaSksYT1uZXcgQXJy
YXkoaSk7Zm9yKGU9MDtlPGk7KytlKXI9UHQobltlXSksb1tlXT1yLnJ8fDAsdVtlXT1yLmd8fDAs
YVtlXT1yLmJ8fDA7cmV0dXJuIG89dChvKSx1PXQodSksYT10KGEpLHIub3BhY2l0eT0xLGZ1bmN0
aW9uKHQpe3JldHVybiByLnI9byh0KSxyLmc9dSh0KSxyLmI9YSh0KSxyKyIifX19ZnVuY3Rpb24g
b24odCxuKXt2YXIgZSxyPW4/bi5sZW5ndGg6MCxpPXQ/TWF0aC5taW4ocix0Lmxlbmd0aCk6MCxv
PW5ldyBBcnJheShpKSx1PW5ldyBBcnJheShyKTtmb3IoZT0wO2U8aTsrK2Upb1tlXT1mbih0W2Vd
LG5bZV0pO2Zvcig7ZTxyOysrZSl1W2VdPW5bZV07cmV0dXJuIGZ1bmN0aW9uKHQpe2ZvcihlPTA7
ZTxpOysrZSl1W2VdPW9bZV0odCk7cmV0dXJuIHV9fWZ1bmN0aW9uIHVuKHQsbil7dmFyIGU9bmV3
IERhdGU7cmV0dXJuIHQ9K3Qsbi09dCxmdW5jdGlvbihyKXtyZXR1cm4gZS5zZXRUaW1lKHQrbipy
KSxlfX1mdW5jdGlvbiBhbih0LG4pe3JldHVybiB0PSt0LG4tPXQsZnVuY3Rpb24oZSl7cmV0dXJu
IHQrbiplfX1mdW5jdGlvbiBjbih0LG4pe3ZhciBlLHI9e30saT17fTtudWxsIT09dCYmIm9iamVj
dCI9PXR5cGVvZiB0fHwodD17fSksbnVsbCE9PW4mJiJvYmplY3QiPT10eXBlb2Ygbnx8KG49e30p
O2ZvcihlIGluIG4pZSBpbiB0P3JbZV09Zm4odFtlXSxuW2VdKTppW2VdPW5bZV07cmV0dXJuIGZ1
bmN0aW9uKHQpe2ZvcihlIGluIHIpaVtlXT1yW2VdKHQpO3JldHVybiBpfX1mdW5jdGlvbiBzbih0
LG4pe3ZhciBlLHIsaSxvPVZmLmxhc3RJbmRleD0kZi5sYXN0SW5kZXg9MCx1PS0xLGE9W10sYz1b
XTtmb3IodCs9IiIsbis9IiI7KGU9VmYuZXhlYyh0KSkmJihyPSRmLmV4ZWMobikpOykoaT1yLmlu
ZGV4KT5vJiYoaT1uLnNsaWNlKG8saSksYVt1XT9hW3VdKz1pOmFbKyt1XT1pKSwoZT1lWzBdKT09
PShyPXJbMF0pP2FbdV0/YVt1XSs9cjphWysrdV09cjooYVsrK3VdPW51bGwsYy5wdXNoKHtpOnUs
eDphbihlLHIpfSkpLG89JGYubGFzdEluZGV4O3JldHVybiBvPG4ubGVuZ3RoJiYoaT1uLnNsaWNl
KG8pLGFbdV0/YVt1XSs9aTphWysrdV09aSksYS5sZW5ndGg8Mj9jWzBdP2Z1bmN0aW9uKHQpe3Jl
dHVybiBmdW5jdGlvbihuKXtyZXR1cm4gdChuKSsiIn19KGNbMF0ueCk6ZnVuY3Rpb24odCl7cmV0
dXJuIGZ1bmN0aW9uKCl7cmV0dXJuIHR9fShuKToobj1jLmxlbmd0aCxmdW5jdGlvbih0KXtmb3Io
dmFyIGUscj0wO3I8bjsrK3IpYVsoZT1jW3JdKS5pXT1lLngodCk7cmV0dXJuIGEuam9pbigiIil9
KX1mdW5jdGlvbiBmbih0LG4pe3ZhciBlLHI9dHlwZW9mIG47cmV0dXJuIG51bGw9PW58fCJib29s
ZWFuIj09PXI/SnQobik6KCJudW1iZXIiPT09cj9hbjoic3RyaW5nIj09PXI/KGU9RXQobikpPyhu
PWUsSGYpOnNuOm4gaW5zdGFuY2VvZiBFdD9IZjpuIGluc3RhbmNlb2YgRGF0ZT91bjpBcnJheS5p
c0FycmF5KG4pP29uOiJmdW5jdGlvbiIhPXR5cGVvZiBuLnZhbHVlT2YmJiJmdW5jdGlvbiIhPXR5
cGVvZiBuLnRvU3RyaW5nfHxpc05hTihuKT9jbjphbikodCxuKX1mdW5jdGlvbiBsbih0LG4pe3Jl
dHVybiB0PSt0LG4tPXQsZnVuY3Rpb24oZSl7cmV0dXJuIE1hdGgucm91bmQodCtuKmUpfX1mdW5j
dGlvbiBobih0LG4sZSxyLGksbyl7dmFyIHUsYSxjO3JldHVybih1PU1hdGguc3FydCh0KnQrbipu
KSkmJih0Lz11LG4vPXUpLChjPXQqZStuKnIpJiYoZS09dCpjLHItPW4qYyksKGE9TWF0aC5zcXJ0
KGUqZStyKnIpKSYmKGUvPWEsci89YSxjLz1hKSx0KnI8biplJiYodD0tdCxuPS1uLGM9LWMsdT0t
dSkse3RyYW5zbGF0ZVg6aSx0cmFuc2xhdGVZOm8scm90YXRlOk1hdGguYXRhbjIobix0KSpXZixz
a2V3WDpNYXRoLmF0YW4oYykqV2Ysc2NhbGVYOnUsc2NhbGVZOmF9fWZ1bmN0aW9uIHBuKHQsbixl
LHIpe2Z1bmN0aW9uIGkodCl7cmV0dXJuIHQubGVuZ3RoP3QucG9wKCkrIiAiOiIifXJldHVybiBm
dW5jdGlvbihvLHUpe3ZhciBhPVtdLGM9W107cmV0dXJuIG89dChvKSx1PXQodSksZnVuY3Rpb24o
dCxyLGksbyx1LGEpe2lmKHQhPT1pfHxyIT09byl7dmFyIGM9dS5wdXNoKCJ0cmFuc2xhdGUoIixu
dWxsLG4sbnVsbCxlKTthLnB1c2goe2k6Yy00LHg6YW4odCxpKX0se2k6Yy0yLHg6YW4ocixvKX0p
fWVsc2UoaXx8bykmJnUucHVzaCgidHJhbnNsYXRlKCIraStuK28rZSl9KG8udHJhbnNsYXRlWCxv
LnRyYW5zbGF0ZVksdS50cmFuc2xhdGVYLHUudHJhbnNsYXRlWSxhLGMpLGZ1bmN0aW9uKHQsbixl
LG8pe3QhPT1uPyh0LW4+MTgwP24rPTM2MDpuLXQ+MTgwJiYodCs9MzYwKSxvLnB1c2goe2k6ZS5w
dXNoKGkoZSkrInJvdGF0ZSgiLG51bGwsciktMix4OmFuKHQsbil9KSk6biYmZS5wdXNoKGkoZSkr
InJvdGF0ZSgiK24rcil9KG8ucm90YXRlLHUucm90YXRlLGEsYyksZnVuY3Rpb24odCxuLGUsbyl7
dCE9PW4/by5wdXNoKHtpOmUucHVzaChpKGUpKyJza2V3WCgiLG51bGwsciktMix4OmFuKHQsbil9
KTpuJiZlLnB1c2goaShlKSsic2tld1goIituK3IpfShvLnNrZXdYLHUuc2tld1gsYSxjKSxmdW5j
dGlvbih0LG4sZSxyLG8sdSl7aWYodCE9PWV8fG4hPT1yKXt2YXIgYT1vLnB1c2goaShvKSsic2Nh
bGUoIixudWxsLCIsIixudWxsLCIpIik7dS5wdXNoKHtpOmEtNCx4OmFuKHQsZSl9LHtpOmEtMix4
OmFuKG4scil9KX1lbHNlIDE9PT1lJiYxPT09cnx8by5wdXNoKGkobykrInNjYWxlKCIrZSsiLCIr
cisiKSIpfShvLnNjYWxlWCxvLnNjYWxlWSx1LnNjYWxlWCx1LnNjYWxlWSxhLGMpLG89dT1udWxs
LGZ1bmN0aW9uKHQpe2Zvcih2YXIgbixlPS0xLHI9Yy5sZW5ndGg7KytlPHI7KWFbKG49Y1tlXSku
aV09bi54KHQpO3JldHVybiBhLmpvaW4oIiIpfX19ZnVuY3Rpb24gZG4odCl7cmV0dXJuKCh0PU1h
dGguZXhwKHQpKSsxL3QpLzJ9ZnVuY3Rpb24gdm4odCxuKXt2YXIgZSxyLGk9dFswXSxvPXRbMV0s
dT10WzJdLGE9blswXSxjPW5bMV0scz1uWzJdLGY9YS1pLGw9Yy1vLGg9ZipmK2wqbDtpZihoPG5s
KXI9TWF0aC5sb2cocy91KS9KZixlPWZ1bmN0aW9uKHQpe3JldHVybltpK3QqZixvK3QqbCx1Kk1h
dGguZXhwKEpmKnQqcildfTtlbHNle3ZhciBwPU1hdGguc3FydChoKSxkPShzKnMtdSp1K3RsKmgp
LygyKnUqS2YqcCksdj0ocypzLXUqdS10bCpoKS8oMipzKktmKnApLGc9TWF0aC5sb2coTWF0aC5z
cXJ0KGQqZCsxKS1kKSxfPU1hdGgubG9nKE1hdGguc3FydCh2KnYrMSktdik7cj0oXy1nKS9KZixl
PWZ1bmN0aW9uKHQpe3ZhciBuPXQqcixlPWRuKGcpLGE9dS8oS2YqcCkqKGUqZnVuY3Rpb24odCl7
cmV0dXJuKCh0PU1hdGguZXhwKDIqdCkpLTEpLyh0KzEpfShKZipuK2cpLWZ1bmN0aW9uKHQpe3Jl
dHVybigodD1NYXRoLmV4cCh0KSktMS90KS8yfShnKSk7cmV0dXJuW2krYSpmLG8rYSpsLHUqZS9k
bihKZipuK2cpXX19cmV0dXJuIGUuZHVyYXRpb249MWUzKnIsZX1mdW5jdGlvbiBnbih0KXtyZXR1
cm4gZnVuY3Rpb24obixlKXt2YXIgcj10KChuPXF0KG4pKS5oLChlPXF0KGUpKS5oKSxpPWVuKG4u
cyxlLnMpLG89ZW4obi5sLGUubCksdT1lbihuLm9wYWNpdHksZS5vcGFjaXR5KTtyZXR1cm4gZnVu
Y3Rpb24odCl7cmV0dXJuIG4uaD1yKHQpLG4ucz1pKHQpLG4ubD1vKHQpLG4ub3BhY2l0eT11KHQp
LG4rIiJ9fX1mdW5jdGlvbiBfbih0KXtyZXR1cm4gZnVuY3Rpb24obixlKXt2YXIgcj10KChuPVh0
KG4pKS5oLChlPVh0KGUpKS5oKSxpPWVuKG4uYyxlLmMpLG89ZW4obi5sLGUubCksdT1lbihuLm9w
YWNpdHksZS5vcGFjaXR5KTtyZXR1cm4gZnVuY3Rpb24odCl7cmV0dXJuIG4uaD1yKHQpLG4uYz1p
KHQpLG4ubD1vKHQpLG4ub3BhY2l0eT11KHQpLG4rIiJ9fX1mdW5jdGlvbiB5bih0KXtyZXR1cm4g
ZnVuY3Rpb24gbihlKXtmdW5jdGlvbiByKG4scil7dmFyIGk9dCgobj0kdChuKSkuaCwocj0kdChy
KSkuaCksbz1lbihuLnMsci5zKSx1PWVuKG4ubCxyLmwpLGE9ZW4obi5vcGFjaXR5LHIub3BhY2l0
eSk7cmV0dXJuIGZ1bmN0aW9uKHQpe3JldHVybiBuLmg9aSh0KSxuLnM9byh0KSxuLmw9dShNYXRo
LnBvdyh0LGUpKSxuLm9wYWNpdHk9YSh0KSxuKyIifX1yZXR1cm4gZT0rZSxyLmdhbW1hPW4scn0o
MSl9ZnVuY3Rpb24gbW4oKXtyZXR1cm4gcGx8fChnbCh4bikscGw9dmwubm93KCkrZGwpfWZ1bmN0
aW9uIHhuKCl7cGw9MH1mdW5jdGlvbiBibigpe3RoaXMuX2NhbGw9dGhpcy5fdGltZT10aGlzLl9u
ZXh0PW51bGx9ZnVuY3Rpb24gd24odCxuLGUpe3ZhciByPW5ldyBibjtyZXR1cm4gci5yZXN0YXJ0
KHQsbixlKSxyfWZ1bmN0aW9uIE1uKCl7bW4oKSwrK2NsO2Zvcih2YXIgdCxuPVlmO247KSh0PXBs
LW4uX3RpbWUpPj0wJiZuLl9jYWxsLmNhbGwobnVsbCx0KSxuPW4uX25leHQ7LS1jbH1mdW5jdGlv
biBUbigpe3BsPShobD12bC5ub3coKSkrZGwsY2w9c2w9MDt0cnl7TW4oKX1maW5hbGx5e2NsPTAs
ZnVuY3Rpb24oKXt2YXIgdCxuLGU9WWYscj0xLzA7Zm9yKDtlOyllLl9jYWxsPyhyPmUuX3RpbWUm
JihyPWUuX3RpbWUpLHQ9ZSxlPWUuX25leHQpOihuPWUuX25leHQsZS5fbmV4dD1udWxsLGU9dD90
Ll9uZXh0PW46WWY9bik7QmY9dCxrbihyKX0oKSxwbD0wfX1mdW5jdGlvbiBObigpe3ZhciB0PXZs
Lm5vdygpLG49dC1obDtuPmxsJiYoZGwtPW4saGw9dCl9ZnVuY3Rpb24ga24odCl7aWYoIWNsKXtz
bCYmKHNsPWNsZWFyVGltZW91dChzbCkpO3QtcGw+MjQ/KHQ8MS8wJiYoc2w9c2V0VGltZW91dChU
bix0LXZsLm5vdygpLWRsKSksZmwmJihmbD1jbGVhckludGVydmFsKGZsKSkpOihmbHx8KGhsPXZs
Lm5vdygpLGZsPXNldEludGVydmFsKE5uLGxsKSksY2w9MSxnbChUbikpfX1mdW5jdGlvbiBTbih0
LG4sZSl7dmFyIHI9bmV3IGJuO3JldHVybiBuPW51bGw9PW4/MDorbixyLnJlc3RhcnQoZnVuY3Rp
b24oZSl7ci5zdG9wKCksdChlK24pfSxuLGUpLHJ9ZnVuY3Rpb24gRW4odCxuLGUscixpLG8pe3Zh
ciB1PXQuX190cmFuc2l0aW9uO2lmKHUpe2lmKGUgaW4gdSlyZXR1cm59ZWxzZSB0Ll9fdHJhbnNp
dGlvbj17fTsoZnVuY3Rpb24odCxuLGUpe2Z1bmN0aW9uIHIoYyl7dmFyIHMsZixsLGg7aWYoZS5z
dGF0ZSE9PXhsKXJldHVybiBvKCk7Zm9yKHMgaW4gYSlpZigoaD1hW3NdKS5uYW1lPT09ZS5uYW1l
KXtpZihoLnN0YXRlPT09d2wpcmV0dXJuIFNuKHIpO2guc3RhdGU9PT1NbD8oaC5zdGF0ZT1ObCxo
LnRpbWVyLnN0b3AoKSxoLm9uLmNhbGwoImludGVycnVwdCIsdCx0Ll9fZGF0YV9fLGguaW5kZXgs
aC5ncm91cCksZGVsZXRlIGFbc10pOitzPG4mJihoLnN0YXRlPU5sLGgudGltZXIuc3RvcCgpLGRl
bGV0ZSBhW3NdKX1pZihTbihmdW5jdGlvbigpe2Uuc3RhdGU9PT13bCYmKGUuc3RhdGU9TWwsZS50
aW1lci5yZXN0YXJ0KGksZS5kZWxheSxlLnRpbWUpLGkoYykpfSksZS5zdGF0ZT1ibCxlLm9uLmNh
bGwoInN0YXJ0Iix0LHQuX19kYXRhX18sZS5pbmRleCxlLmdyb3VwKSxlLnN0YXRlPT09Ymwpe2Zv
cihlLnN0YXRlPXdsLHU9bmV3IEFycmF5KGw9ZS50d2Vlbi5sZW5ndGgpLHM9MCxmPS0xO3M8bDsr
K3MpKGg9ZS50d2VlbltzXS52YWx1ZS5jYWxsKHQsdC5fX2RhdGFfXyxlLmluZGV4LGUuZ3JvdXAp
KSYmKHVbKytmXT1oKTt1Lmxlbmd0aD1mKzF9fWZ1bmN0aW9uIGkobil7Zm9yKHZhciByPW48ZS5k
dXJhdGlvbj9lLmVhc2UuY2FsbChudWxsLG4vZS5kdXJhdGlvbik6KGUudGltZXIucmVzdGFydChv
KSxlLnN0YXRlPVRsLDEpLGk9LTEsYT11Lmxlbmd0aDsrK2k8YTspdVtpXS5jYWxsKG51bGwscik7
ZS5zdGF0ZT09PVRsJiYoZS5vbi5jYWxsKCJlbmQiLHQsdC5fX2RhdGFfXyxlLmluZGV4LGUuZ3Jv
dXApLG8oKSl9ZnVuY3Rpb24gbygpe2Uuc3RhdGU9TmwsZS50aW1lci5zdG9wKCksZGVsZXRlIGFb
bl07Zm9yKHZhciByIGluIGEpcmV0dXJuO2RlbGV0ZSB0Ll9fdHJhbnNpdGlvbn12YXIgdSxhPXQu
X190cmFuc2l0aW9uO2Fbbl09ZSxlLnRpbWVyPXduKGZ1bmN0aW9uKHQpe2Uuc3RhdGU9eGwsZS50
aW1lci5yZXN0YXJ0KHIsZS5kZWxheSxlLnRpbWUpLGUuZGVsYXk8PXQmJnIodC1lLmRlbGF5KX0s
MCxlLnRpbWUpfSkodCxlLHtuYW1lOm4saW5kZXg6cixncm91cDppLG9uOl9sLHR3ZWVuOnlsLHRp
bWU6by50aW1lLGRlbGF5Om8uZGVsYXksZHVyYXRpb246by5kdXJhdGlvbixlYXNlOm8uZWFzZSx0
aW1lcjpudWxsLHN0YXRlOm1sfSl9ZnVuY3Rpb24gQW4odCxuKXt2YXIgZT16bih0LG4pO2lmKGUu
c3RhdGU+bWwpdGhyb3cgbmV3IEVycm9yKCJ0b28gbGF0ZTsgYWxyZWFkeSBzY2hlZHVsZWQiKTty
ZXR1cm4gZX1mdW5jdGlvbiBDbih0LG4pe3ZhciBlPXpuKHQsbik7aWYoZS5zdGF0ZT5ibCl0aHJv
dyBuZXcgRXJyb3IoInRvbyBsYXRlOyBhbHJlYWR5IHN0YXJ0ZWQiKTtyZXR1cm4gZX1mdW5jdGlv
biB6bih0LG4pe3ZhciBlPXQuX190cmFuc2l0aW9uO2lmKCFlfHwhKGU9ZVtuXSkpdGhyb3cgbmV3
IEVycm9yKCJ0cmFuc2l0aW9uIG5vdCBmb3VuZCIpO3JldHVybiBlfWZ1bmN0aW9uIFBuKHQsbil7
dmFyIGUscixpLG89dC5fX3RyYW5zaXRpb24sdT0hMDtpZihvKXtuPW51bGw9PW4/bnVsbDpuKyIi
O2ZvcihpIGluIG8pKGU9b1tpXSkubmFtZT09PW4/KHI9ZS5zdGF0ZT5ibCYmZS5zdGF0ZTxUbCxl
LnN0YXRlPU5sLGUudGltZXIuc3RvcCgpLHImJmUub24uY2FsbCgiaW50ZXJydXB0Iix0LHQuX19k
YXRhX18sZS5pbmRleCxlLmdyb3VwKSxkZWxldGUgb1tpXSk6dT0hMTt1JiZkZWxldGUgdC5fX3Ry
YW5zaXRpb259fWZ1bmN0aW9uIFJuKHQsbixlKXt2YXIgcj10Ll9pZDtyZXR1cm4gdC5lYWNoKGZ1
bmN0aW9uKCl7dmFyIHQ9Q24odGhpcyxyKTsodC52YWx1ZXx8KHQudmFsdWU9e30pKVtuXT1lLmFw
cGx5KHRoaXMsYXJndW1lbnRzKX0pLGZ1bmN0aW9uKHQpe3JldHVybiB6bih0LHIpLnZhbHVlW25d
fX1mdW5jdGlvbiBMbih0LG4pe3ZhciBlO3JldHVybigibnVtYmVyIj09dHlwZW9mIG4/YW46biBp
bnN0YW5jZW9mIEV0P0hmOihlPUV0KG4pKT8obj1lLEhmKTpzbikodCxuKX1mdW5jdGlvbiBxbih0
LG4sZSxyKXt0aGlzLl9ncm91cHM9dCx0aGlzLl9wYXJlbnRzPW4sdGhpcy5fbmFtZT1lLHRoaXMu
X2lkPXJ9ZnVuY3Rpb24gRG4odCl7cmV0dXJuIGF0KCkudHJhbnNpdGlvbih0KX1mdW5jdGlvbiBV
bigpe3JldHVybisrU2x9ZnVuY3Rpb24gT24odCl7cmV0dXJuKCh0Kj0yKTw9MT90KnQ6LS10Kigy
LXQpKzEpLzJ9ZnVuY3Rpb24gRm4odCl7cmV0dXJuKCh0Kj0yKTw9MT90KnQqdDoodC09MikqdCp0
KzIpLzJ9ZnVuY3Rpb24gSW4odCl7cmV0dXJuKDEtTWF0aC5jb3MoUGwqdCkpLzJ9ZnVuY3Rpb24g
WW4odCl7cmV0dXJuKCh0Kj0yKTw9MT9NYXRoLnBvdygyLDEwKnQtMTApOjItTWF0aC5wb3coMiwx
MC0xMCp0KSkvMn1mdW5jdGlvbiBCbih0KXtyZXR1cm4oKHQqPTIpPD0xPzEtTWF0aC5zcXJ0KDEt
dCp0KTpNYXRoLnNxcnQoMS0odC09MikqdCkrMSkvMn1mdW5jdGlvbiBIbih0KXtyZXR1cm4odD0r
dCk8TGw/SGwqdCp0OnQ8RGw/SGwqKHQtPXFsKSp0K1VsOnQ8Rmw/SGwqKHQtPU9sKSp0K0lsOkhs
Kih0LT1ZbCkqdCtCbH1mdW5jdGlvbiBqbih0LG4pe2Zvcih2YXIgZTshKGU9dC5fX3RyYW5zaXRp
b24pfHwhKGU9ZVtuXSk7KWlmKCEodD10LnBhcmVudE5vZGUpKXJldHVybiBRbC50aW1lPW1uKCks
UWw7cmV0dXJuIGV9ZnVuY3Rpb24gWG4odCl7cmV0dXJuIGZ1bmN0aW9uKCl7cmV0dXJuIHR9fWZ1
bmN0aW9uIFZuKCl7dC5ldmVudC5zdG9wSW1tZWRpYXRlUHJvcGFnYXRpb24oKX1mdW5jdGlvbiAk
bigpe3QuZXZlbnQucHJldmVudERlZmF1bHQoKSx0LmV2ZW50LnN0b3BJbW1lZGlhdGVQcm9wYWdh
dGlvbigpfWZ1bmN0aW9uIFduKHQpe3JldHVybnt0eXBlOnR9fWZ1bmN0aW9uIFpuKCl7cmV0dXJu
IXQuZXZlbnQuYnV0dG9ufWZ1bmN0aW9uIEduKCl7dmFyIHQ9dGhpcy5vd25lclNWR0VsZW1lbnR8
fHRoaXM7cmV0dXJuW1swLDBdLFt0LndpZHRoLmJhc2VWYWwudmFsdWUsdC5oZWlnaHQuYmFzZVZh
bC52YWx1ZV1dfWZ1bmN0aW9uIFFuKHQpe2Zvcig7IXQuX19icnVzaDspaWYoISh0PXQucGFyZW50
Tm9kZSkpcmV0dXJuO3JldHVybiB0Ll9fYnJ1c2h9ZnVuY3Rpb24gSm4odCl7cmV0dXJuIHRbMF1b
MF09PT10WzFdWzBdfHx0WzBdWzFdPT09dFsxXVsxXX1mdW5jdGlvbiBLbihuKXtmdW5jdGlvbiBl
KHQpe3ZhciBlPXQucHJvcGVydHkoIl9fYnJ1c2giLGEpLnNlbGVjdEFsbCgiLm92ZXJsYXkiKS5k
YXRhKFtXbigib3ZlcmxheSIpXSk7ZS5lbnRlcigpLmFwcGVuZCgicmVjdCIpLmF0dHIoImNsYXNz
Iiwib3ZlcmxheSIpLmF0dHIoInBvaW50ZXItZXZlbnRzIiwiYWxsIikuYXR0cigiY3Vyc29yIix1
aC5vdmVybGF5KS5tZXJnZShlKS5lYWNoKGZ1bmN0aW9uKCl7dmFyIHQ9UW4odGhpcykuZXh0ZW50
O2N0KHRoaXMpLmF0dHIoIngiLHRbMF1bMF0pLmF0dHIoInkiLHRbMF1bMV0pLmF0dHIoIndpZHRo
Iix0WzFdWzBdLXRbMF1bMF0pLmF0dHIoImhlaWdodCIsdFsxXVsxXS10WzBdWzFdKX0pLHQuc2Vs
ZWN0QWxsKCIuc2VsZWN0aW9uIikuZGF0YShbV24oInNlbGVjdGlvbiIpXSkuZW50ZXIoKS5hcHBl
bmQoInJlY3QiKS5hdHRyKCJjbGFzcyIsInNlbGVjdGlvbiIpLmF0dHIoImN1cnNvciIsdWguc2Vs
ZWN0aW9uKS5hdHRyKCJmaWxsIiwiIzc3NyIpLmF0dHIoImZpbGwtb3BhY2l0eSIsLjMpLmF0dHIo
InN0cm9rZSIsIiNmZmYiKS5hdHRyKCJzaGFwZS1yZW5kZXJpbmciLCJjcmlzcEVkZ2VzIik7dmFy
IGk9dC5zZWxlY3RBbGwoIi5oYW5kbGUiKS5kYXRhKG4uaGFuZGxlcyxmdW5jdGlvbih0KXtyZXR1
cm4gdC50eXBlfSk7aS5leGl0KCkucmVtb3ZlKCksaS5lbnRlcigpLmFwcGVuZCgicmVjdCIpLmF0
dHIoImNsYXNzIixmdW5jdGlvbih0KXtyZXR1cm4iaGFuZGxlIGhhbmRsZS0tIit0LnR5cGV9KS5h
dHRyKCJjdXJzb3IiLGZ1bmN0aW9uKHQpe3JldHVybiB1aFt0LnR5cGVdfSksdC5lYWNoKHIpLmF0
dHIoImZpbGwiLCJub25lIikuYXR0cigicG9pbnRlci1ldmVudHMiLCJhbGwiKS5zdHlsZSgiLXdl
YmtpdC10YXAtaGlnaGxpZ2h0LWNvbG9yIiwicmdiYSgwLDAsMCwwKSIpLm9uKCJtb3VzZWRvd24u
YnJ1c2ggdG91Y2hzdGFydC5icnVzaCIsdSl9ZnVuY3Rpb24gcigpe3ZhciB0PWN0KHRoaXMpLG49
UW4odGhpcykuc2VsZWN0aW9uO24/KHQuc2VsZWN0QWxsKCIuc2VsZWN0aW9uIikuc3R5bGUoImRp
c3BsYXkiLG51bGwpLmF0dHIoIngiLG5bMF1bMF0pLmF0dHIoInkiLG5bMF1bMV0pLmF0dHIoIndp
ZHRoIixuWzFdWzBdLW5bMF1bMF0pLmF0dHIoImhlaWdodCIsblsxXVsxXS1uWzBdWzFdKSx0LnNl
bGVjdEFsbCgiLmhhbmRsZSIpLnN0eWxlKCJkaXNwbGF5IixudWxsKS5hdHRyKCJ4IixmdW5jdGlv
bih0KXtyZXR1cm4iZSI9PT10LnR5cGVbdC50eXBlLmxlbmd0aC0xXT9uWzFdWzBdLWgvMjpuWzBd
WzBdLWgvMn0pLmF0dHIoInkiLGZ1bmN0aW9uKHQpe3JldHVybiJzIj09PXQudHlwZVswXT9uWzFd
WzFdLWgvMjpuWzBdWzFdLWgvMn0pLmF0dHIoIndpZHRoIixmdW5jdGlvbih0KXtyZXR1cm4ibiI9
PT10LnR5cGV8fCJzIj09PXQudHlwZT9uWzFdWzBdLW5bMF1bMF0raDpofSkuYXR0cigiaGVpZ2h0
IixmdW5jdGlvbih0KXtyZXR1cm4iZSI9PT10LnR5cGV8fCJ3Ij09PXQudHlwZT9uWzFdWzFdLW5b
MF1bMV0raDpofSkpOnQuc2VsZWN0QWxsKCIuc2VsZWN0aW9uLC5oYW5kbGUiKS5zdHlsZSgiZGlz
cGxheSIsIm5vbmUiKS5hdHRyKCJ4IixudWxsKS5hdHRyKCJ5IixudWxsKS5hdHRyKCJ3aWR0aCIs
bnVsbCkuYXR0cigiaGVpZ2h0IixudWxsKX1mdW5jdGlvbiBpKHQsbil7cmV0dXJuIHQuX19icnVz
aC5lbWl0dGVyfHxuZXcgbyh0LG4pfWZ1bmN0aW9uIG8odCxuKXt0aGlzLnRoYXQ9dCx0aGlzLmFy
Z3M9bix0aGlzLnN0YXRlPXQuX19icnVzaCx0aGlzLmFjdGl2ZT0wfWZ1bmN0aW9uIHUoKXtmdW5j
dGlvbiBlKCl7dmFyIHQ9cHQodyk7IUx8fHh8fGJ8fChNYXRoLmFicyh0WzBdLURbMF0pPk1hdGgu
YWJzKHRbMV0tRFsxXSk/Yj0hMDp4PSEwKSxEPXQsbT0hMCwkbigpLG8oKX1mdW5jdGlvbiBvKCl7
dmFyIHQ7c3dpdGNoKF89RFswXS1xWzBdLHk9RFsxXS1xWzFdLFQpe2Nhc2UgdGg6Y2FzZSBLbDpO
JiYoXz1NYXRoLm1heChDLWEsTWF0aC5taW4oUC1wLF8pKSxzPWErXyxkPXArXyksayYmKHk9TWF0
aC5tYXgoei1sLE1hdGgubWluKFItdix5KSksaD1sK3ksZz12K3kpO2JyZWFrO2Nhc2Ugbmg6Tjww
PyhfPU1hdGgubWF4KEMtYSxNYXRoLm1pbihQLWEsXykpLHM9YStfLGQ9cCk6Tj4wJiYoXz1NYXRo
Lm1heChDLXAsTWF0aC5taW4oUC1wLF8pKSxzPWEsZD1wK18pLGs8MD8oeT1NYXRoLm1heCh6LWws
TWF0aC5taW4oUi1sLHkpKSxoPWwreSxnPXYpOms+MCYmKHk9TWF0aC5tYXgoei12LE1hdGgubWlu
KFItdix5KSksaD1sLGc9dit5KTticmVhaztjYXNlIGVoOk4mJihzPU1hdGgubWF4KEMsTWF0aC5t
aW4oUCxhLV8qTikpLGQ9TWF0aC5tYXgoQyxNYXRoLm1pbihQLHArXypOKSkpLGsmJihoPU1hdGgu
bWF4KHosTWF0aC5taW4oUixsLXkqaykpLGc9TWF0aC5tYXgoeixNYXRoLm1pbihSLHYreSprKSkp
fWQ8cyYmKE4qPS0xLHQ9YSxhPXAscD10LHQ9cyxzPWQsZD10LE0gaW4gYWgmJkYuYXR0cigiY3Vy
c29yIix1aFtNPWFoW01dXSkpLGc8aCYmKGsqPS0xLHQ9bCxsPXYsdj10LHQ9aCxoPWcsZz10LE0g
aW4gY2gmJkYuYXR0cigiY3Vyc29yIix1aFtNPWNoW01dXSkpLFMuc2VsZWN0aW9uJiYoQT1TLnNl
bGVjdGlvbikseCYmKHM9QVswXVswXSxkPUFbMV1bMF0pLGImJihoPUFbMF1bMV0sZz1BWzFdWzFd
KSxBWzBdWzBdPT09cyYmQVswXVsxXT09PWgmJkFbMV1bMF09PT1kJiZBWzFdWzFdPT09Z3x8KFMu
c2VsZWN0aW9uPVtbcyxoXSxbZCxnXV0sci5jYWxsKHcpLFUuYnJ1c2goKSl9ZnVuY3Rpb24gdSgp
e2lmKFZuKCksdC5ldmVudC50b3VjaGVzKXtpZih0LmV2ZW50LnRvdWNoZXMubGVuZ3RoKXJldHVy
bjtjJiZjbGVhclRpbWVvdXQoYyksYz1zZXRUaW1lb3V0KGZ1bmN0aW9uKCl7Yz1udWxsfSw1MDAp
LE8ub24oInRvdWNobW92ZS5icnVzaCB0b3VjaGVuZC5icnVzaCB0b3VjaGNhbmNlbC5icnVzaCIs
bnVsbCl9ZWxzZSB5dCh0LmV2ZW50LnZpZXcsbSksSS5vbigia2V5ZG93bi5icnVzaCBrZXl1cC5i
cnVzaCBtb3VzZW1vdmUuYnJ1c2ggbW91c2V1cC5icnVzaCIsbnVsbCk7Ty5hdHRyKCJwb2ludGVy
LWV2ZW50cyIsImFsbCIpLEYuYXR0cigiY3Vyc29yIix1aC5vdmVybGF5KSxTLnNlbGVjdGlvbiYm
KEE9Uy5zZWxlY3Rpb24pLEpuKEEpJiYoUy5zZWxlY3Rpb249bnVsbCxyLmNhbGwodykpLFUuZW5k
KCl9aWYodC5ldmVudC50b3VjaGVzKXtpZih0LmV2ZW50LmNoYW5nZWRUb3VjaGVzLmxlbmd0aDx0
LmV2ZW50LnRvdWNoZXMubGVuZ3RoKXJldHVybiAkbigpfWVsc2UgaWYoYylyZXR1cm47aWYoZi5h
cHBseSh0aGlzLGFyZ3VtZW50cykpe3ZhciBhLHMsbCxoLHAsZCx2LGcsXyx5LG0seCxiLHc9dGhp
cyxNPXQuZXZlbnQudGFyZ2V0Ll9fZGF0YV9fLnR5cGUsVD0ic2VsZWN0aW9uIj09PSh0LmV2ZW50
Lm1ldGFLZXk/TT0ib3ZlcmxheSI6TSk/S2w6dC5ldmVudC5hbHRLZXk/ZWg6bmgsTj1uPT09aWg/
bnVsbDpzaFtNXSxrPW49PT1yaD9udWxsOmZoW01dLFM9UW4odyksRT1TLmV4dGVudCxBPVMuc2Vs
ZWN0aW9uLEM9RVswXVswXSx6PUVbMF1bMV0sUD1FWzFdWzBdLFI9RVsxXVsxXSxMPU4mJmsmJnQu
ZXZlbnQuc2hpZnRLZXkscT1wdCh3KSxEPXEsVT1pKHcsYXJndW1lbnRzKS5iZWZvcmVzdGFydCgp
OyJvdmVybGF5Ij09PU0/Uy5zZWxlY3Rpb249QT1bW2E9bj09PWloP0M6cVswXSxsPW49PT1yaD96
OnFbMV1dLFtwPW49PT1paD9QOmEsdj1uPT09cmg/UjpsXV06KGE9QVswXVswXSxsPUFbMF1bMV0s
cD1BWzFdWzBdLHY9QVsxXVsxXSkscz1hLGg9bCxkPXAsZz12O3ZhciBPPWN0KHcpLmF0dHIoInBv
aW50ZXItZXZlbnRzIiwibm9uZSIpLEY9Ty5zZWxlY3RBbGwoIi5vdmVybGF5IikuYXR0cigiY3Vy
c29yIix1aFtNXSk7aWYodC5ldmVudC50b3VjaGVzKU8ub24oInRvdWNobW92ZS5icnVzaCIsZSwh
MCkub24oInRvdWNoZW5kLmJydXNoIHRvdWNoY2FuY2VsLmJydXNoIix1LCEwKTtlbHNle3ZhciBJ
PWN0KHQuZXZlbnQudmlldykub24oImtleWRvd24uYnJ1c2giLGZ1bmN0aW9uKCl7c3dpdGNoKHQu
ZXZlbnQua2V5Q29kZSl7Y2FzZSAxNjpMPU4mJms7YnJlYWs7Y2FzZSAxODpUPT09bmgmJihOJiYo
cD1kLV8qTixhPXMrXypOKSxrJiYodj1nLXkqayxsPWgreSprKSxUPWVoLG8oKSk7YnJlYWs7Y2Fz
ZSAzMjpUIT09bmgmJlQhPT1laHx8KE48MD9wPWQtXzpOPjAmJihhPXMtXyksazwwP3Y9Zy15Oms+
MCYmKGw9aC15KSxUPXRoLEYuYXR0cigiY3Vyc29yIix1aC5zZWxlY3Rpb24pLG8oKSk7YnJlYWs7
ZGVmYXVsdDpyZXR1cm59JG4oKX0sITApLm9uKCJrZXl1cC5icnVzaCIsZnVuY3Rpb24oKXtzd2l0
Y2godC5ldmVudC5rZXlDb2RlKXtjYXNlIDE2OkwmJih4PWI9TD0hMSxvKCkpO2JyZWFrO2Nhc2Ug
MTg6VD09PWVoJiYoTjwwP3A9ZDpOPjAmJihhPXMpLGs8MD92PWc6az4wJiYobD1oKSxUPW5oLG8o
KSk7YnJlYWs7Y2FzZSAzMjpUPT09dGgmJih0LmV2ZW50LmFsdEtleT8oTiYmKHA9ZC1fKk4sYT1z
K18qTiksayYmKHY9Zy15KmssbD1oK3kqayksVD1laCk6KE48MD9wPWQ6Tj4wJiYoYT1zKSxrPDA/
dj1nOms+MCYmKGw9aCksVD1uaCksRi5hdHRyKCJjdXJzb3IiLHVoW01dKSxvKCkpO2JyZWFrO2Rl
ZmF1bHQ6cmV0dXJufSRuKCl9LCEwKS5vbigibW91c2Vtb3ZlLmJydXNoIixlLCEwKS5vbigibW91
c2V1cC5icnVzaCIsdSwhMCk7X3QodC5ldmVudC52aWV3KX1WbigpLFBuKHcpLHIuY2FsbCh3KSxV
LnN0YXJ0KCl9fWZ1bmN0aW9uIGEoKXt2YXIgdD10aGlzLl9fYnJ1c2h8fHtzZWxlY3Rpb246bnVs
bH07cmV0dXJuIHQuZXh0ZW50PXMuYXBwbHkodGhpcyxhcmd1bWVudHMpLHQuZGltPW4sdH12YXIg
YyxzPUduLGY9Wm4sbD1OKGUsInN0YXJ0IiwiYnJ1c2giLCJlbmQiKSxoPTY7cmV0dXJuIGUubW92
ZT1mdW5jdGlvbih0LGUpe3Quc2VsZWN0aW9uP3Qub24oInN0YXJ0LmJydXNoIixmdW5jdGlvbigp
e2kodGhpcyxhcmd1bWVudHMpLmJlZm9yZXN0YXJ0KCkuc3RhcnQoKX0pLm9uKCJpbnRlcnJ1cHQu
YnJ1c2ggZW5kLmJydXNoIixmdW5jdGlvbigpe2kodGhpcyxhcmd1bWVudHMpLmVuZCgpfSkudHdl
ZW4oImJydXNoIixmdW5jdGlvbigpe2Z1bmN0aW9uIHQodCl7dS5zZWxlY3Rpb249MT09PXQmJkpu
KHMpP251bGw6Zih0KSxyLmNhbGwobyksYS5icnVzaCgpfXZhciBvPXRoaXMsdT1vLl9fYnJ1c2gs
YT1pKG8sYXJndW1lbnRzKSxjPXUuc2VsZWN0aW9uLHM9bi5pbnB1dCgiZnVuY3Rpb24iPT10eXBl
b2YgZT9lLmFwcGx5KHRoaXMsYXJndW1lbnRzKTplLHUuZXh0ZW50KSxmPWZuKGMscyk7cmV0dXJu
IGMmJnM/dDp0KDEpfSk6dC5lYWNoKGZ1bmN0aW9uKCl7dmFyIHQ9YXJndW1lbnRzLG89dGhpcy5f
X2JydXNoLHU9bi5pbnB1dCgiZnVuY3Rpb24iPT10eXBlb2YgZT9lLmFwcGx5KHRoaXMsdCk6ZSxv
LmV4dGVudCksYT1pKHRoaXMsdCkuYmVmb3Jlc3RhcnQoKTtQbih0aGlzKSxvLnNlbGVjdGlvbj1u
dWxsPT11fHxKbih1KT9udWxsOnUsci5jYWxsKHRoaXMpLGEuc3RhcnQoKS5icnVzaCgpLmVuZCgp
fSl9LG8ucHJvdG90eXBlPXtiZWZvcmVzdGFydDpmdW5jdGlvbigpe3JldHVybiAxPT0rK3RoaXMu
YWN0aXZlJiYodGhpcy5zdGF0ZS5lbWl0dGVyPXRoaXMsdGhpcy5zdGFydGluZz0hMCksdGhpc30s
c3RhcnQ6ZnVuY3Rpb24oKXtyZXR1cm4gdGhpcy5zdGFydGluZyYmKHRoaXMuc3RhcnRpbmc9ITEs
dGhpcy5lbWl0KCJzdGFydCIpKSx0aGlzfSxicnVzaDpmdW5jdGlvbigpe3JldHVybiB0aGlzLmVt
aXQoImJydXNoIiksdGhpc30sZW5kOmZ1bmN0aW9uKCl7cmV0dXJuIDA9PS0tdGhpcy5hY3RpdmUm
JihkZWxldGUgdGhpcy5zdGF0ZS5lbWl0dGVyLHRoaXMuZW1pdCgiZW5kIikpLHRoaXN9LGVtaXQ6
ZnVuY3Rpb24odCl7aXQobmV3IGZ1bmN0aW9uKHQsbixlKXt0aGlzLnRhcmdldD10LHRoaXMudHlw
ZT1uLHRoaXMuc2VsZWN0aW9uPWV9KGUsdCxuLm91dHB1dCh0aGlzLnN0YXRlLnNlbGVjdGlvbikp
LGwuYXBwbHksbCxbdCx0aGlzLnRoYXQsdGhpcy5hcmdzXSl9fSxlLmV4dGVudD1mdW5jdGlvbih0
KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8ocz0iZnVuY3Rpb24iPT10eXBlb2YgdD90OlhuKFtb
K3RbMF1bMF0sK3RbMF1bMV1dLFsrdFsxXVswXSwrdFsxXVsxXV1dKSxlKTpzfSxlLmZpbHRlcj1m
dW5jdGlvbih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oZj0iZnVuY3Rpb24iPT10eXBlb2Yg
dD90OlhuKCEhdCksZSk6Zn0sZS5oYW5kbGVTaXplPWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVu
dHMubGVuZ3RoPyhoPSt0LGUpOmh9LGUub249ZnVuY3Rpb24oKXt2YXIgdD1sLm9uLmFwcGx5KGws
YXJndW1lbnRzKTtyZXR1cm4gdD09PWw/ZTp0fSxlfWZ1bmN0aW9uIHRlKHQpe3JldHVybiBmdW5j
dGlvbigpe3JldHVybiB0fX1mdW5jdGlvbiBuZSgpe3RoaXMuX3gwPXRoaXMuX3kwPXRoaXMuX3gx
PXRoaXMuX3kxPW51bGwsdGhpcy5fPSIifWZ1bmN0aW9uIGVlKCl7cmV0dXJuIG5ldyBuZX1mdW5j
dGlvbiByZSh0KXtyZXR1cm4gdC5zb3VyY2V9ZnVuY3Rpb24gaWUodCl7cmV0dXJuIHQudGFyZ2V0
fWZ1bmN0aW9uIG9lKHQpe3JldHVybiB0LnJhZGl1c31mdW5jdGlvbiB1ZSh0KXtyZXR1cm4gdC5z
dGFydEFuZ2xlfWZ1bmN0aW9uIGFlKHQpe3JldHVybiB0LmVuZEFuZ2xlfWZ1bmN0aW9uIGNlKCl7
fWZ1bmN0aW9uIHNlKHQsbil7dmFyIGU9bmV3IGNlO2lmKHQgaW5zdGFuY2VvZiBjZSl0LmVhY2go
ZnVuY3Rpb24odCxuKXtlLnNldChuLHQpfSk7ZWxzZSBpZihBcnJheS5pc0FycmF5KHQpKXt2YXIg
cixpPS0xLG89dC5sZW5ndGg7aWYobnVsbD09bilmb3IoOysraTxvOyllLnNldChpLHRbaV0pO2Vs
c2UgZm9yKDsrK2k8bzspZS5zZXQobihyPXRbaV0saSx0KSxyKX1lbHNlIGlmKHQpZm9yKHZhciB1
IGluIHQpZS5zZXQodSx0W3VdKTtyZXR1cm4gZX1mdW5jdGlvbiBmZSgpe3JldHVybnt9fWZ1bmN0
aW9uIGxlKHQsbixlKXt0W25dPWV9ZnVuY3Rpb24gaGUoKXtyZXR1cm4gc2UoKX1mdW5jdGlvbiBw
ZSh0LG4sZSl7dC5zZXQobixlKX1mdW5jdGlvbiBkZSgpe31mdW5jdGlvbiB2ZSh0LG4pe3ZhciBl
PW5ldyBkZTtpZih0IGluc3RhbmNlb2YgZGUpdC5lYWNoKGZ1bmN0aW9uKHQpe2UuYWRkKHQpfSk7
ZWxzZSBpZih0KXt2YXIgcj0tMSxpPXQubGVuZ3RoO2lmKG51bGw9PW4pZm9yKDsrK3I8aTspZS5h
ZGQodFtyXSk7ZWxzZSBmb3IoOysrcjxpOyllLmFkZChuKHRbcl0scix0KSl9cmV0dXJuIGV9ZnVu
Y3Rpb24gZ2UodCl7cmV0dXJuIG5ldyBGdW5jdGlvbigiZCIsInJldHVybiB7Iit0Lm1hcChmdW5j
dGlvbih0LG4pe3JldHVybiBKU09OLnN0cmluZ2lmeSh0KSsiOiBkWyIrbisiXSJ9KS5qb2luKCIs
IikrIn0iKX1mdW5jdGlvbiBfZSh0KXtmdW5jdGlvbiBuKHQsbil7ZnVuY3Rpb24gZSgpe2lmKHMp
cmV0dXJuIE1oO2lmKGYpcmV0dXJuIGY9ITEsd2g7dmFyIG4sZSxyPWE7aWYodC5jaGFyQ29kZUF0
KHIpPT09VGgpe2Zvcig7YSsrPHUmJnQuY2hhckNvZGVBdChhKSE9PVRofHx0LmNoYXJDb2RlQXQo
KythKT09PVRoOyk7cmV0dXJuKG49YSk+PXU/cz0hMDooZT10LmNoYXJDb2RlQXQoYSsrKSk9PT1O
aD9mPSEwOmU9PT1raCYmKGY9ITAsdC5jaGFyQ29kZUF0KGEpPT09TmgmJisrYSksdC5zbGljZShy
KzEsbi0xKS5yZXBsYWNlKC8iIi9nLCciJyl9Zm9yKDthPHU7KXtpZigoZT10LmNoYXJDb2RlQXQo
bj1hKyspKT09PU5oKWY9ITA7ZWxzZSBpZihlPT09a2gpZj0hMCx0LmNoYXJDb2RlQXQoYSk9PT1O
aCYmKythO2Vsc2UgaWYoZSE9PW8pY29udGludWU7cmV0dXJuIHQuc2xpY2UocixuKX1yZXR1cm4g
cz0hMCx0LnNsaWNlKHIsdSl9dmFyIHIsaT1bXSx1PXQubGVuZ3RoLGE9MCxjPTAscz11PD0wLGY9
ITE7Zm9yKHQuY2hhckNvZGVBdCh1LTEpPT09TmgmJi0tdSx0LmNoYXJDb2RlQXQodS0xKT09PWto
JiYtLXU7KHI9ZSgpKSE9PU1oOyl7Zm9yKHZhciBsPVtdO3IhPT13aCYmciE9PU1oOylsLnB1c2go
cikscj1lKCk7biYmbnVsbD09KGw9bihsLGMrKykpfHxpLnB1c2gobCl9cmV0dXJuIGl9ZnVuY3Rp
b24gZShuKXtyZXR1cm4gbi5tYXAocikuam9pbih0KX1mdW5jdGlvbiByKHQpe3JldHVybiBudWxs
PT10PyIiOmkudGVzdCh0Kz0iIik/JyInK3QucmVwbGFjZSgvIi9nLCciIicpKyciJzp0fXZhciBp
PW5ldyBSZWdFeHAoJ1siJyt0KyJcblxyXSIpLG89dC5jaGFyQ29kZUF0KDApO3JldHVybntwYXJz
ZTpmdW5jdGlvbih0LGUpe3ZhciByLGksbz1uKHQsZnVuY3Rpb24odCxuKXtpZihyKXJldHVybiBy
KHQsbi0xKTtpPXQscj1lP2Z1bmN0aW9uKHQsbil7dmFyIGU9Z2UodCk7cmV0dXJuIGZ1bmN0aW9u
KHIsaSl7cmV0dXJuIG4oZShyKSxpLHQpfX0odCxlKTpnZSh0KX0pO3JldHVybiBvLmNvbHVtbnM9
aXx8W10sb30scGFyc2VSb3dzOm4sZm9ybWF0OmZ1bmN0aW9uKG4sZSl7cmV0dXJuIG51bGw9PWUm
JihlPWZ1bmN0aW9uKHQpe3ZhciBuPU9iamVjdC5jcmVhdGUobnVsbCksZT1bXTtyZXR1cm4gdC5m
b3JFYWNoKGZ1bmN0aW9uKHQpe2Zvcih2YXIgciBpbiB0KXIgaW4gbnx8ZS5wdXNoKG5bcl09cil9
KSxlfShuKSksW2UubWFwKHIpLmpvaW4odCldLmNvbmNhdChuLm1hcChmdW5jdGlvbihuKXtyZXR1
cm4gZS5tYXAoZnVuY3Rpb24odCl7cmV0dXJuIHIoblt0XSl9KS5qb2luKHQpfSkpLmpvaW4oIlxu
Iil9LGZvcm1hdFJvd3M6ZnVuY3Rpb24odCl7cmV0dXJuIHQubWFwKGUpLmpvaW4oIlxuIil9fX1m
dW5jdGlvbiB5ZSh0KXtyZXR1cm4gZnVuY3Rpb24oKXtyZXR1cm4gdH19ZnVuY3Rpb24gbWUoKXty
ZXR1cm4gMWUtNiooTWF0aC5yYW5kb20oKS0uNSl9ZnVuY3Rpb24geGUodCxuLGUscil7aWYoaXNO
YU4obil8fGlzTmFOKGUpKXJldHVybiB0O3ZhciBpLG8sdSxhLGMscyxmLGwsaCxwPXQuX3Jvb3Qs
ZD17ZGF0YTpyfSx2PXQuX3gwLGc9dC5feTAsXz10Ll94MSx5PXQuX3kxO2lmKCFwKXJldHVybiB0
Ll9yb290PWQsdDtmb3IoO3AubGVuZ3RoOylpZigocz1uPj0obz0oditfKS8yKSk/dj1vOl89bywo
Zj1lPj0odT0oZyt5KS8yKSk/Zz11Onk9dSxpPXAsIShwPXBbbD1mPDwxfHNdKSlyZXR1cm4gaVts
XT1kLHQ7aWYoYT0rdC5feC5jYWxsKG51bGwscC5kYXRhKSxjPSt0Ll95LmNhbGwobnVsbCxwLmRh
dGEpLG49PT1hJiZlPT09YylyZXR1cm4gZC5uZXh0PXAsaT9pW2xdPWQ6dC5fcm9vdD1kLHQ7ZG97
aT1pP2lbbF09bmV3IEFycmF5KDQpOnQuX3Jvb3Q9bmV3IEFycmF5KDQpLChzPW4+PShvPSh2K18p
LzIpKT92PW86Xz1vLChmPWU+PSh1PShnK3kpLzIpKT9nPXU6eT11fXdoaWxlKChsPWY8PDF8cyk9
PShoPShjPj11KTw8MXxhPj1vKSk7cmV0dXJuIGlbaF09cCxpW2xdPWQsdH1mdW5jdGlvbiBiZSh0
LG4sZSxyLGkpe3RoaXMubm9kZT10LHRoaXMueDA9bix0aGlzLnkwPWUsdGhpcy54MT1yLHRoaXMu
eTE9aX1mdW5jdGlvbiB3ZSh0KXtyZXR1cm4gdFswXX1mdW5jdGlvbiBNZSh0KXtyZXR1cm4gdFsx
XX1mdW5jdGlvbiBUZSh0LG4sZSl7dmFyIHI9bmV3IE5lKG51bGw9PW4/d2U6bixudWxsPT1lP01l
OmUsTmFOLE5hTixOYU4sTmFOKTtyZXR1cm4gbnVsbD09dD9yOnIuYWRkQWxsKHQpfWZ1bmN0aW9u
IE5lKHQsbixlLHIsaSxvKXt0aGlzLl94PXQsdGhpcy5feT1uLHRoaXMuX3gwPWUsdGhpcy5feTA9
cix0aGlzLl94MT1pLHRoaXMuX3kxPW8sdGhpcy5fcm9vdD12b2lkIDB9ZnVuY3Rpb24ga2UodCl7
Zm9yKHZhciBuPXtkYXRhOnQuZGF0YX0sZT1uO3Q9dC5uZXh0OyllPWUubmV4dD17ZGF0YTp0LmRh
dGF9O3JldHVybiBufWZ1bmN0aW9uIFNlKHQpe3JldHVybiB0LngrdC52eH1mdW5jdGlvbiBFZSh0
KXtyZXR1cm4gdC55K3Qudnl9ZnVuY3Rpb24gQWUodCl7cmV0dXJuIHQuaW5kZXh9ZnVuY3Rpb24g
Q2UodCxuKXt2YXIgZT10LmdldChuKTtpZighZSl0aHJvdyBuZXcgRXJyb3IoIm1pc3Npbmc6ICIr
bik7cmV0dXJuIGV9ZnVuY3Rpb24gemUodCl7cmV0dXJuIHQueH1mdW5jdGlvbiBQZSh0KXtyZXR1
cm4gdC55fWZ1bmN0aW9uIFJlKHQsbil7aWYoKGU9KHQ9bj90LnRvRXhwb25lbnRpYWwobi0xKTp0
LnRvRXhwb25lbnRpYWwoKSkuaW5kZXhPZigiZSIpKTwwKXJldHVybiBudWxsO3ZhciBlLHI9dC5z
bGljZSgwLGUpO3JldHVybltyLmxlbmd0aD4xP3JbMF0rci5zbGljZSgyKTpyLCt0LnNsaWNlKGUr
MSldfWZ1bmN0aW9uIExlKHQpe3JldHVybih0PVJlKE1hdGguYWJzKHQpKSk/dFsxXTpOYU59ZnVu
Y3Rpb24gcWUodCxuKXt2YXIgZT1SZSh0LG4pO2lmKCFlKXJldHVybiB0KyIiO3ZhciByPWVbMF0s
aT1lWzFdO3JldHVybiBpPDA/IjAuIituZXcgQXJyYXkoLWkpLmpvaW4oIjAiKStyOnIubGVuZ3Ro
PmkrMT9yLnNsaWNlKDAsaSsxKSsiLiIrci5zbGljZShpKzEpOnIrbmV3IEFycmF5KGktci5sZW5n
dGgrMikuam9pbigiMCIpfWZ1bmN0aW9uIERlKHQpe3JldHVybiBuZXcgVWUodCl9ZnVuY3Rpb24g
VWUodCl7aWYoIShuPUJoLmV4ZWModCkpKXRocm93IG5ldyBFcnJvcigiaW52YWxpZCBmb3JtYXQ6
ICIrdCk7dmFyIG4sZT1uWzFdfHwiICIscj1uWzJdfHwiPiIsaT1uWzNdfHwiLSIsbz1uWzRdfHwi
Iix1PSEhbls1XSxhPW5bNl0mJituWzZdLGM9ISFuWzddLHM9bls4XSYmK25bOF0uc2xpY2UoMSks
Zj1uWzldfHwiIjsibiI9PT1mPyhjPSEwLGY9ImciKTpZaFtmXXx8KGY9IiIpLCh1fHwiMCI9PT1l
JiYiPSI9PT1yKSYmKHU9ITAsZT0iMCIscj0iPSIpLHRoaXMuZmlsbD1lLHRoaXMuYWxpZ249cix0
aGlzLnNpZ249aSx0aGlzLnN5bWJvbD1vLHRoaXMuemVybz11LHRoaXMud2lkdGg9YSx0aGlzLmNv
bW1hPWMsdGhpcy5wcmVjaXNpb249cyx0aGlzLnR5cGU9Zn1mdW5jdGlvbiBPZSh0KXtyZXR1cm4g
dH1mdW5jdGlvbiBGZSh0KXtmdW5jdGlvbiBuKHQpe2Z1bmN0aW9uIG4odCl7dmFyIG4scix1LGY9
Zyx4PV87aWYoImMiPT09dil4PXkodCkreCx0PSIiO2Vsc2V7dmFyIGI9KHQ9K3QpPDA7aWYodD15
KE1hdGguYWJzKHQpLGQpLGImJjA9PSt0JiYoYj0hMSksZj0oYj8iKCI9PT1zP3M6Ii0iOiItIj09
PXN8fCIoIj09PXM/IiI6cykrZix4PSgicyI9PT12P2poWzgrT2gvM106IiIpK3grKGImJiIoIj09
PXM/IikiOiIiKSxtKWZvcihuPS0xLHI9dC5sZW5ndGg7KytuPHI7KWlmKDQ4Pih1PXQuY2hhckNv
ZGVBdChuKSl8fHU+NTcpe3g9KDQ2PT09dT9pK3Quc2xpY2UobisxKTp0LnNsaWNlKG4pKSt4LHQ9
dC5zbGljZSgwLG4pO2JyZWFrfX1wJiYhbCYmKHQ9ZSh0LDEvMCkpO3ZhciB3PWYubGVuZ3RoK3Qu
bGVuZ3RoK3gubGVuZ3RoLE09dzxoP25ldyBBcnJheShoLXcrMSkuam9pbihhKToiIjtzd2l0Y2go
cCYmbCYmKHQ9ZShNK3QsTS5sZW5ndGg/aC14Lmxlbmd0aDoxLzApLE09IiIpLGMpe2Nhc2UiPCI6
dD1mK3QreCtNO2JyZWFrO2Nhc2UiPSI6dD1mK00rdCt4O2JyZWFrO2Nhc2UiXiI6dD1NLnNsaWNl
KDAsdz1NLmxlbmd0aD4+MSkrZit0K3grTS5zbGljZSh3KTticmVhaztkZWZhdWx0OnQ9TStmK3Qr
eH1yZXR1cm4gbyh0KX12YXIgYT0odD1EZSh0KSkuZmlsbCxjPXQuYWxpZ24scz10LnNpZ24sZj10
LnN5bWJvbCxsPXQuemVybyxoPXQud2lkdGgscD10LmNvbW1hLGQ9dC5wcmVjaXNpb24sdj10LnR5
cGUsZz0iJCI9PT1mP3JbMF06IiMiPT09ZiYmL1tib3hYXS8udGVzdCh2KT8iMCIrdi50b0xvd2Vy
Q2FzZSgpOiIiLF89IiQiPT09Zj9yWzFdOi9bJXBdLy50ZXN0KHYpP3U6IiIseT1ZaFt2XSxtPSF2
fHwvW2RlZmdwcnMlXS8udGVzdCh2KTtyZXR1cm4gZD1udWxsPT1kP3Y/NjoxMjovW2dwcnNdLy50
ZXN0KHYpP01hdGgubWF4KDEsTWF0aC5taW4oMjEsZCkpOk1hdGgubWF4KDAsTWF0aC5taW4oMjAs
ZCkpLG4udG9TdHJpbmc9ZnVuY3Rpb24oKXtyZXR1cm4gdCsiIn0sbn12YXIgZT10Lmdyb3VwaW5n
JiZ0LnRob3VzYW5kcz9mdW5jdGlvbih0LG4pe3JldHVybiBmdW5jdGlvbihlLHIpe2Zvcih2YXIg
aT1lLmxlbmd0aCxvPVtdLHU9MCxhPXRbMF0sYz0wO2k+MCYmYT4wJiYoYythKzE+ciYmKGE9TWF0
aC5tYXgoMSxyLWMpKSxvLnB1c2goZS5zdWJzdHJpbmcoaS09YSxpK2EpKSwhKChjKz1hKzEpPnIp
KTspYT10W3U9KHUrMSkldC5sZW5ndGhdO3JldHVybiBvLnJldmVyc2UoKS5qb2luKG4pfX0odC5n
cm91cGluZyx0LnRob3VzYW5kcyk6T2Uscj10LmN1cnJlbmN5LGk9dC5kZWNpbWFsLG89dC5udW1l
cmFscz9mdW5jdGlvbih0KXtyZXR1cm4gZnVuY3Rpb24obil7cmV0dXJuIG4ucmVwbGFjZSgvWzAt
OV0vZyxmdW5jdGlvbihuKXtyZXR1cm4gdFsrbl19KX19KHQubnVtZXJhbHMpOk9lLHU9dC5wZXJj
ZW50fHwiJSI7cmV0dXJue2Zvcm1hdDpuLGZvcm1hdFByZWZpeDpmdW5jdGlvbih0LGUpe3ZhciBy
PW4oKHQ9RGUodCksdC50eXBlPSJmIix0KSksaT0zKk1hdGgubWF4KC04LE1hdGgubWluKDgsTWF0
aC5mbG9vcihMZShlKS8zKSkpLG89TWF0aC5wb3coMTAsLWkpLHU9amhbOCtpLzNdO3JldHVybiBm
dW5jdGlvbih0KXtyZXR1cm4gcihvKnQpK3V9fX19ZnVuY3Rpb24gSWUobil7cmV0dXJuIEhoPUZl
KG4pLHQuZm9ybWF0PUhoLmZvcm1hdCx0LmZvcm1hdFByZWZpeD1IaC5mb3JtYXRQcmVmaXgsSGh9
ZnVuY3Rpb24gWWUodCl7cmV0dXJuIE1hdGgubWF4KDAsLUxlKE1hdGguYWJzKHQpKSl9ZnVuY3Rp
b24gQmUodCxuKXtyZXR1cm4gTWF0aC5tYXgoMCwzKk1hdGgubWF4KC04LE1hdGgubWluKDgsTWF0
aC5mbG9vcihMZShuKS8zKSkpLUxlKE1hdGguYWJzKHQpKSl9ZnVuY3Rpb24gSGUodCxuKXtyZXR1
cm4gdD1NYXRoLmFicyh0KSxuPU1hdGguYWJzKG4pLXQsTWF0aC5tYXgoMCxMZShuKS1MZSh0KSkr
MX1mdW5jdGlvbiBqZSgpe3JldHVybiBuZXcgWGV9ZnVuY3Rpb24gWGUoKXt0aGlzLnJlc2V0KCl9
ZnVuY3Rpb24gVmUodCxuLGUpe3ZhciByPXQucz1uK2UsaT1yLW4sbz1yLWk7dC50PW4tbysoZS1p
KX1mdW5jdGlvbiAkZSh0KXtyZXR1cm4gdD4xPzA6dDwtMT9OcDpNYXRoLmFjb3ModCl9ZnVuY3Rp
b24gV2UodCl7cmV0dXJuIHQ+MT9rcDp0PC0xPy1rcDpNYXRoLmFzaW4odCl9ZnVuY3Rpb24gWmUo
dCl7cmV0dXJuKHQ9RnAodC8yKSkqdH1mdW5jdGlvbiBHZSgpe31mdW5jdGlvbiBRZSh0LG4pe3Qm
JmpwLmhhc093blByb3BlcnR5KHQudHlwZSkmJmpwW3QudHlwZV0odCxuKX1mdW5jdGlvbiBKZSh0
LG4sZSl7dmFyIHIsaT0tMSxvPXQubGVuZ3RoLWU7Zm9yKG4ubGluZVN0YXJ0KCk7KytpPG87KXI9
dFtpXSxuLnBvaW50KHJbMF0sclsxXSxyWzJdKTtuLmxpbmVFbmQoKX1mdW5jdGlvbiBLZSh0LG4p
e3ZhciBlPS0xLHI9dC5sZW5ndGg7Zm9yKG4ucG9seWdvblN0YXJ0KCk7KytlPHI7KUplKHRbZV0s
biwxKTtuLnBvbHlnb25FbmQoKX1mdW5jdGlvbiB0cih0LG4pe3QmJkhwLmhhc093blByb3BlcnR5
KHQudHlwZSk/SHBbdC50eXBlXSh0LG4pOlFlKHQsbil9ZnVuY3Rpb24gbnIoKXskcC5wb2ludD1y
cn1mdW5jdGlvbiBlcigpe2lyKFhoLFZoKX1mdW5jdGlvbiBycih0LG4peyRwLnBvaW50PWlyLFho
PXQsVmg9biwkaD10Kj1DcCxXaD1McChuPShuKj1DcCkvMitTcCksWmg9RnAobil9ZnVuY3Rpb24g
aXIodCxuKXtuPShuKj1DcCkvMitTcDt2YXIgZT0odCo9Q3ApLSRoLHI9ZT49MD8xOi0xLGk9cipl
LG89THAobiksdT1GcChuKSxhPVpoKnUsYz1XaCpvK2EqTHAoaSkscz1hKnIqRnAoaSk7WHAuYWRk
KFJwKHMsYykpLCRoPXQsV2g9byxaaD11fWZ1bmN0aW9uIG9yKHQpe3JldHVybltScCh0WzFdLHRb
MF0pLFdlKHRbMl0pXX1mdW5jdGlvbiB1cih0KXt2YXIgbj10WzBdLGU9dFsxXSxyPUxwKGUpO3Jl
dHVybltyKkxwKG4pLHIqRnAobiksRnAoZSldfWZ1bmN0aW9uIGFyKHQsbil7cmV0dXJuIHRbMF0q
blswXSt0WzFdKm5bMV0rdFsyXSpuWzJdfWZ1bmN0aW9uIGNyKHQsbil7cmV0dXJuW3RbMV0qblsy
XS10WzJdKm5bMV0sdFsyXSpuWzBdLXRbMF0qblsyXSx0WzBdKm5bMV0tdFsxXSpuWzBdXX1mdW5j
dGlvbiBzcih0LG4pe3RbMF0rPW5bMF0sdFsxXSs9blsxXSx0WzJdKz1uWzJdfWZ1bmN0aW9uIGZy
KHQsbil7cmV0dXJuW3RbMF0qbix0WzFdKm4sdFsyXSpuXX1mdW5jdGlvbiBscih0KXt2YXIgbj1Z
cCh0WzBdKnRbMF0rdFsxXSp0WzFdK3RbMl0qdFsyXSk7dFswXS89bix0WzFdLz1uLHRbMl0vPW59
ZnVuY3Rpb24gaHIodCxuKXtpcC5wdXNoKG9wPVtHaD10LEpoPXRdKSxuPFFoJiYoUWg9biksbj5L
aCYmKEtoPW4pfWZ1bmN0aW9uIHByKHQsbil7dmFyIGU9dXIoW3QqQ3AsbipDcF0pO2lmKHJwKXt2
YXIgcj1jcihycCxlKSxpPWNyKFtyWzFdLC1yWzBdLDBdLHIpO2xyKGkpLGk9b3IoaSk7dmFyIG8s
dT10LXRwLGE9dT4wPzE6LTEsYz1pWzBdKkFwKmEscz16cCh1KT4xODA7c14oYSp0cDxjJiZjPGEq
dCk/KG89aVsxXSpBcCk+S2gmJihLaD1vKTooYz0oYyszNjApJTM2MC0xODAsc14oYSp0cDxjJiZj
PGEqdCk/KG89LWlbMV0qQXApPFFoJiYoUWg9byk6KG48UWgmJihRaD1uKSxuPktoJiYoS2g9bikp
KSxzP3Q8dHA/bXIoR2gsdCk+bXIoR2gsSmgpJiYoSmg9dCk6bXIodCxKaCk+bXIoR2gsSmgpJiYo
R2g9dCk6Smg+PUdoPyh0PEdoJiYoR2g9dCksdD5KaCYmKEpoPXQpKTp0PnRwP21yKEdoLHQpPm1y
KEdoLEpoKSYmKEpoPXQpOm1yKHQsSmgpPm1yKEdoLEpoKSYmKEdoPXQpfWVsc2UgaXAucHVzaChv
cD1bR2g9dCxKaD10XSk7bjxRaCYmKFFoPW4pLG4+S2gmJihLaD1uKSxycD1lLHRwPXR9ZnVuY3Rp
b24gZHIoKXtacC5wb2ludD1wcn1mdW5jdGlvbiB2cigpe29wWzBdPUdoLG9wWzFdPUpoLFpwLnBv
aW50PWhyLHJwPW51bGx9ZnVuY3Rpb24gZ3IodCxuKXtpZihycCl7dmFyIGU9dC10cDtXcC5hZGQo
enAoZSk+MTgwP2UrKGU+MD8zNjA6LTM2MCk6ZSl9ZWxzZSBucD10LGVwPW47JHAucG9pbnQodCxu
KSxwcih0LG4pfWZ1bmN0aW9uIF9yKCl7JHAubGluZVN0YXJ0KCl9ZnVuY3Rpb24geXIoKXtncihu
cCxlcCksJHAubGluZUVuZCgpLHpwKFdwKT5NcCYmKEdoPS0oSmg9MTgwKSksb3BbMF09R2gsb3Bb
MV09SmgscnA9bnVsbH1mdW5jdGlvbiBtcih0LG4pe3JldHVybihuLT10KTwwP24rMzYwOm59ZnVu
Y3Rpb24geHIodCxuKXtyZXR1cm4gdFswXS1uWzBdfWZ1bmN0aW9uIGJyKHQsbil7cmV0dXJuIHRb
MF08PXRbMV0/dFswXTw9biYmbjw9dFsxXTpuPHRbMF18fHRbMV08bn1mdW5jdGlvbiB3cih0LG4p
e3QqPUNwO3ZhciBlPUxwKG4qPUNwKTtNcihlKkxwKHQpLGUqRnAodCksRnAobikpfWZ1bmN0aW9u
IE1yKHQsbixlKXtjcCs9KHQtY3ApLysrdXAsc3ArPShuLXNwKS91cCxmcCs9KGUtZnApL3VwfWZ1
bmN0aW9uIFRyKCl7R3AucG9pbnQ9TnJ9ZnVuY3Rpb24gTnIodCxuKXt0Kj1DcDt2YXIgZT1McChu
Kj1DcCk7bXA9ZSpMcCh0KSx4cD1lKkZwKHQpLGJwPUZwKG4pLEdwLnBvaW50PWtyLE1yKG1wLHhw
LGJwKX1mdW5jdGlvbiBrcih0LG4pe3QqPUNwO3ZhciBlPUxwKG4qPUNwKSxyPWUqTHAodCksaT1l
KkZwKHQpLG89RnAobiksdT1ScChZcCgodT14cCpvLWJwKmkpKnUrKHU9YnAqci1tcCpvKSp1Kyh1
PW1wKmkteHAqcikqdSksbXAqcit4cCppK2JwKm8pO2FwKz11LGxwKz11KihtcCsobXA9cikpLGhw
Kz11Kih4cCsoeHA9aSkpLHBwKz11KihicCsoYnA9bykpLE1yKG1wLHhwLGJwKX1mdW5jdGlvbiBT
cigpe0dwLnBvaW50PXdyfWZ1bmN0aW9uIEVyKCl7R3AucG9pbnQ9Q3J9ZnVuY3Rpb24gQXIoKXt6
cihfcCx5cCksR3AucG9pbnQ9d3J9ZnVuY3Rpb24gQ3IodCxuKXtfcD10LHlwPW4sdCo9Q3Asbio9
Q3AsR3AucG9pbnQ9enI7dmFyIGU9THAobik7bXA9ZSpMcCh0KSx4cD1lKkZwKHQpLGJwPUZwKG4p
LE1yKG1wLHhwLGJwKX1mdW5jdGlvbiB6cih0LG4pe3QqPUNwO3ZhciBlPUxwKG4qPUNwKSxyPWUq
THAodCksaT1lKkZwKHQpLG89RnAobiksdT14cCpvLWJwKmksYT1icCpyLW1wKm8sYz1tcCppLXhw
KnIscz1ZcCh1KnUrYSphK2MqYyksZj1XZShzKSxsPXMmJi1mL3M7ZHArPWwqdSx2cCs9bCphLGdw
Kz1sKmMsYXArPWYsbHArPWYqKG1wKyhtcD1yKSksaHArPWYqKHhwKyh4cD1pKSkscHArPWYqKGJw
KyhicD1vKSksTXIobXAseHAsYnApfWZ1bmN0aW9uIFByKHQpe3JldHVybiBmdW5jdGlvbigpe3Jl
dHVybiB0fX1mdW5jdGlvbiBScih0LG4pe2Z1bmN0aW9uIGUoZSxyKXtyZXR1cm4gZT10KGUsciks
bihlWzBdLGVbMV0pfXJldHVybiB0LmludmVydCYmbi5pbnZlcnQmJihlLmludmVydD1mdW5jdGlv
bihlLHIpe3JldHVybihlPW4uaW52ZXJ0KGUscikpJiZ0LmludmVydChlWzBdLGVbMV0pfSksZX1m
dW5jdGlvbiBMcih0LG4pe3JldHVyblt0Pk5wP3QtRXA6dDwtTnA/dCtFcDp0LG5dfWZ1bmN0aW9u
IHFyKHQsbixlKXtyZXR1cm4odCU9RXApP258fGU/UnIoVXIodCksT3IobixlKSk6VXIodCk6bnx8
ZT9PcihuLGUpOkxyfWZ1bmN0aW9uIERyKHQpe3JldHVybiBmdW5jdGlvbihuLGUpe3JldHVybiBu
Kz10LFtuPk5wP24tRXA6bjwtTnA/bitFcDpuLGVdfX1mdW5jdGlvbiBVcih0KXt2YXIgbj1Ecih0
KTtyZXR1cm4gbi5pbnZlcnQ9RHIoLXQpLG59ZnVuY3Rpb24gT3IodCxuKXtmdW5jdGlvbiBlKHQs
bil7dmFyIGU9THAobiksYT1McCh0KSplLGM9RnAodCkqZSxzPUZwKG4pLGY9cypyK2EqaTtyZXR1
cm5bUnAoYypvLWYqdSxhKnItcyppKSxXZShmKm8rYyp1KV19dmFyIHI9THAodCksaT1GcCh0KSxv
PUxwKG4pLHU9RnAobik7cmV0dXJuIGUuaW52ZXJ0PWZ1bmN0aW9uKHQsbil7dmFyIGU9THAobiks
YT1McCh0KSplLGM9RnAodCkqZSxzPUZwKG4pLGY9cypvLWMqdTtyZXR1cm5bUnAoYypvK3MqdSxh
KnIrZippKSxXZShmKnItYSppKV19LGV9ZnVuY3Rpb24gRnIodCl7ZnVuY3Rpb24gbihuKXtyZXR1
cm4gbj10KG5bMF0qQ3AsblsxXSpDcCksblswXSo9QXAsblsxXSo9QXAsbn1yZXR1cm4gdD1xcih0
WzBdKkNwLHRbMV0qQ3AsdC5sZW5ndGg+Mj90WzJdKkNwOjApLG4uaW52ZXJ0PWZ1bmN0aW9uKG4p
e3JldHVybiBuPXQuaW52ZXJ0KG5bMF0qQ3AsblsxXSpDcCksblswXSo9QXAsblsxXSo9QXAsbn0s
bn1mdW5jdGlvbiBJcih0LG4sZSxyLGksbyl7aWYoZSl7dmFyIHU9THAobiksYT1GcChuKSxjPXIq
ZTtudWxsPT1pPyhpPW4rcipFcCxvPW4tYy8yKTooaT1Zcih1LGkpLG89WXIodSxvKSwocj4wP2k8
bzppPm8pJiYoaSs9cipFcCkpO2Zvcih2YXIgcyxmPWk7cj4wP2Y+bzpmPG87Zi09YylzPW9yKFt1
LC1hKkxwKGYpLC1hKkZwKGYpXSksdC5wb2ludChzWzBdLHNbMV0pfX1mdW5jdGlvbiBZcih0LG4p
eyhuPXVyKG4pKVswXS09dCxscihuKTt2YXIgZT0kZSgtblsxXSk7cmV0dXJuKCgtblsyXTwwPy1l
OmUpK0VwLU1wKSVFcH1mdW5jdGlvbiBCcigpe3ZhciB0LG49W107cmV0dXJue3BvaW50OmZ1bmN0
aW9uKG4sZSl7dC5wdXNoKFtuLGVdKX0sbGluZVN0YXJ0OmZ1bmN0aW9uKCl7bi5wdXNoKHQ9W10p
fSxsaW5lRW5kOkdlLHJlam9pbjpmdW5jdGlvbigpe24ubGVuZ3RoPjEmJm4ucHVzaChuLnBvcCgp
LmNvbmNhdChuLnNoaWZ0KCkpKX0scmVzdWx0OmZ1bmN0aW9uKCl7dmFyIGU9bjtyZXR1cm4gbj1b
XSx0PW51bGwsZX19fWZ1bmN0aW9uIEhyKHQsbil7cmV0dXJuIHpwKHRbMF0tblswXSk8TXAmJnpw
KHRbMV0tblsxXSk8TXB9ZnVuY3Rpb24ganIodCxuLGUscil7dGhpcy54PXQsdGhpcy56PW4sdGhp
cy5vPWUsdGhpcy5lPXIsdGhpcy52PSExLHRoaXMubj10aGlzLnA9bnVsbH1mdW5jdGlvbiBYcih0
LG4sZSxyLGkpe3ZhciBvLHUsYT1bXSxjPVtdO2lmKHQuZm9yRWFjaChmdW5jdGlvbih0KXtpZigh
KChuPXQubGVuZ3RoLTEpPD0wKSl7dmFyIG4sZSxyPXRbMF0sdT10W25dO2lmKEhyKHIsdSkpe2Zv
cihpLmxpbmVTdGFydCgpLG89MDtvPG47KytvKWkucG9pbnQoKHI9dFtvXSlbMF0sclsxXSk7aS5s
aW5lRW5kKCl9ZWxzZSBhLnB1c2goZT1uZXcganIocix0LG51bGwsITApKSxjLnB1c2goZS5vPW5l
dyBqcihyLG51bGwsZSwhMSkpLGEucHVzaChlPW5ldyBqcih1LHQsbnVsbCwhMSkpLGMucHVzaChl
Lm89bmV3IGpyKHUsbnVsbCxlLCEwKSl9fSksYS5sZW5ndGgpe2ZvcihjLnNvcnQobiksVnIoYSks
VnIoYyksbz0wLHU9Yy5sZW5ndGg7bzx1OysrbyljW29dLmU9ZT0hZTtmb3IodmFyIHMsZixsPWFb
MF07Oyl7Zm9yKHZhciBoPWwscD0hMDtoLnY7KWlmKChoPWgubik9PT1sKXJldHVybjtzPWgueixp
LmxpbmVTdGFydCgpO2Rve2lmKGgudj1oLm8udj0hMCxoLmUpe2lmKHApZm9yKG89MCx1PXMubGVu
Z3RoO288dTsrK28paS5wb2ludCgoZj1zW29dKVswXSxmWzFdKTtlbHNlIHIoaC54LGgubi54LDEs
aSk7aD1oLm59ZWxzZXtpZihwKWZvcihzPWgucC56LG89cy5sZW5ndGgtMTtvPj0wOy0tbylpLnBv
aW50KChmPXNbb10pWzBdLGZbMV0pO2Vsc2UgcihoLngsaC5wLngsLTEsaSk7aD1oLnB9cz0oaD1o
Lm8pLnoscD0hcH13aGlsZSghaC52KTtpLmxpbmVFbmQoKX19fWZ1bmN0aW9uIFZyKHQpe2lmKG49
dC5sZW5ndGgpe2Zvcih2YXIgbixlLHI9MCxpPXRbMF07KytyPG47KWkubj1lPXRbcl0sZS5wPWks
aT1lO2kubj1lPXRbMF0sZS5wPWl9fWZ1bmN0aW9uICRyKHQsbil7dmFyIGU9blswXSxyPW5bMV0s
aT1bRnAoZSksLUxwKGUpLDBdLG89MCx1PTA7Y2QucmVzZXQoKTtmb3IodmFyIGE9MCxjPXQubGVu
Z3RoO2E8YzsrK2EpaWYoZj0ocz10W2FdKS5sZW5ndGgpZm9yKHZhciBzLGYsbD1zW2YtMV0saD1s
WzBdLHA9bFsxXS8yK1NwLGQ9RnAocCksdj1McChwKSxnPTA7ZzxmOysrZyxoPXksZD14LHY9Yixs
PV8pe3ZhciBfPXNbZ10seT1fWzBdLG09X1sxXS8yK1NwLHg9RnAobSksYj1McChtKSx3PXktaCxN
PXc+PTA/MTotMSxUPU0qdyxOPVQ+TnAsaz1kKng7aWYoY2QuYWRkKFJwKGsqTSpGcChUKSx2KmIr
aypMcChUKSkpLG8rPU4/dytNKkVwOncsTl5oPj1lXnk+PWUpe3ZhciBTPWNyKHVyKGwpLHVyKF8p
KTtscihTKTt2YXIgRT1jcihpLFMpO2xyKEUpO3ZhciBBPShOXnc+PTA/LTE6MSkqV2UoRVsyXSk7
KHI+QXx8cj09PUEmJihTWzBdfHxTWzFdKSkmJih1Kz1OXnc+PTA/MTotMSl9fXJldHVybihvPC1N
cHx8bzxNcCYmY2Q8LU1wKV4xJnV9ZnVuY3Rpb24gV3IodCxuLGUscil7cmV0dXJuIGZ1bmN0aW9u
KGkpe2Z1bmN0aW9uIG8obixlKXt0KG4sZSkmJmkucG9pbnQobixlKX1mdW5jdGlvbiB1KHQsbil7
di5wb2ludCh0LG4pfWZ1bmN0aW9uIGEoKXt4LnBvaW50PXUsdi5saW5lU3RhcnQoKX1mdW5jdGlv
biBjKCl7eC5wb2ludD1vLHYubGluZUVuZCgpfWZ1bmN0aW9uIHModCxuKXtkLnB1c2goW3Qsbl0p
LHkucG9pbnQodCxuKX1mdW5jdGlvbiBmKCl7eS5saW5lU3RhcnQoKSxkPVtdfWZ1bmN0aW9uIGwo
KXtzKGRbMF1bMF0sZFswXVsxXSkseS5saW5lRW5kKCk7dmFyIHQsbixlLHIsbz15LmNsZWFuKCks
dT1fLnJlc3VsdCgpLGE9dS5sZW5ndGg7aWYoZC5wb3AoKSxoLnB1c2goZCksZD1udWxsLGEpaWYo
MSZvKXtpZihlPXVbMF0sKG49ZS5sZW5ndGgtMSk+MCl7Zm9yKG18fChpLnBvbHlnb25TdGFydCgp
LG09ITApLGkubGluZVN0YXJ0KCksdD0wO3Q8bjsrK3QpaS5wb2ludCgocj1lW3RdKVswXSxyWzFd
KTtpLmxpbmVFbmQoKX19ZWxzZSBhPjEmJjImbyYmdS5wdXNoKHUucG9wKCkuY29uY2F0KHUuc2hp
ZnQoKSkpLHAucHVzaCh1LmZpbHRlcihacikpfXZhciBoLHAsZCx2PW4oaSksXz1CcigpLHk9bihf
KSxtPSExLHg9e3BvaW50Om8sbGluZVN0YXJ0OmEsbGluZUVuZDpjLHBvbHlnb25TdGFydDpmdW5j
dGlvbigpe3gucG9pbnQ9cyx4LmxpbmVTdGFydD1mLHgubGluZUVuZD1sLHA9W10saD1bXX0scG9s
eWdvbkVuZDpmdW5jdGlvbigpe3gucG9pbnQ9byx4LmxpbmVTdGFydD1hLHgubGluZUVuZD1jLHA9
ZyhwKTt2YXIgdD0kcihoLHIpO3AubGVuZ3RoPyhtfHwoaS5wb2x5Z29uU3RhcnQoKSxtPSEwKSxY
cihwLEdyLHQsZSxpKSk6dCYmKG18fChpLnBvbHlnb25TdGFydCgpLG09ITApLGkubGluZVN0YXJ0
KCksZShudWxsLG51bGwsMSxpKSxpLmxpbmVFbmQoKSksbSYmKGkucG9seWdvbkVuZCgpLG09ITEp
LHA9aD1udWxsfSxzcGhlcmU6ZnVuY3Rpb24oKXtpLnBvbHlnb25TdGFydCgpLGkubGluZVN0YXJ0
KCksZShudWxsLG51bGwsMSxpKSxpLmxpbmVFbmQoKSxpLnBvbHlnb25FbmQoKX19O3JldHVybiB4
fX1mdW5jdGlvbiBacih0KXtyZXR1cm4gdC5sZW5ndGg+MX1mdW5jdGlvbiBHcih0LG4pe3JldHVy
bigodD10LngpWzBdPDA/dFsxXS1rcC1NcDprcC10WzFdKS0oKG49bi54KVswXTwwP25bMV0ta3At
TXA6a3AtblsxXSl9ZnVuY3Rpb24gUXIodCl7ZnVuY3Rpb24gbih0LG4pe3JldHVybiBMcCh0KSpM
cChuKT5pfWZ1bmN0aW9uIGUodCxuLGUpe3ZhciByPVsxLDAsMF0sbz1jcih1cih0KSx1cihuKSks
dT1hcihvLG8pLGE9b1swXSxjPXUtYSphO2lmKCFjKXJldHVybiFlJiZ0O3ZhciBzPWkqdS9jLGY9
LWkqYS9jLGw9Y3IocixvKSxoPWZyKHIscyk7c3IoaCxmcihvLGYpKTt2YXIgcD1sLGQ9YXIoaCxw
KSx2PWFyKHAscCksZz1kKmQtdiooYXIoaCxoKS0xKTtpZighKGc8MCkpe3ZhciBfPVlwKGcpLHk9
ZnIocCwoLWQtXykvdik7aWYoc3IoeSxoKSx5PW9yKHkpLCFlKXJldHVybiB5O3ZhciBtLHg9dFsw
XSxiPW5bMF0sdz10WzFdLE09blsxXTtiPHgmJihtPXgseD1iLGI9bSk7dmFyIFQ9Yi14LE49enAo
VC1OcCk8TXA7aWYoIU4mJk08dyYmKG09dyx3PU0sTT1tKSxOfHxUPE1wP04/dytNPjBeeVsxXTwo
enAoeVswXS14KTxNcD93Ok0pOnc8PXlbMV0mJnlbMV08PU06VD5OcF4oeDw9eVswXSYmeVswXTw9
Yikpe3ZhciBrPWZyKHAsKC1kK18pL3YpO3JldHVybiBzcihrLGgpLFt5LG9yKGspXX19fWZ1bmN0
aW9uIHIobixlKXt2YXIgcj11P3Q6TnAtdCxpPTA7cmV0dXJuIG48LXI/aXw9MTpuPnImJihpfD0y
KSxlPC1yP2l8PTQ6ZT5yJiYoaXw9OCksaX12YXIgaT1McCh0KSxvPTYqQ3AsdT1pPjAsYT16cChp
KT5NcDtyZXR1cm4gV3IobixmdW5jdGlvbih0KXt2YXIgaSxvLGMscyxmO3JldHVybntsaW5lU3Rh
cnQ6ZnVuY3Rpb24oKXtzPWM9ITEsZj0xfSxwb2ludDpmdW5jdGlvbihsLGgpe3ZhciBwLGQ9W2ws
aF0sdj1uKGwsaCksZz11P3Y/MDpyKGwsaCk6dj9yKGwrKGw8MD9OcDotTnApLGgpOjA7aWYoIWkm
JihzPWM9dikmJnQubGluZVN0YXJ0KCksdiE9PWMmJighKHA9ZShpLGQpKXx8SHIoaSxwKXx8SHIo
ZCxwKSkmJihkWzBdKz1NcCxkWzFdKz1NcCx2PW4oZFswXSxkWzFdKSksdiE9PWMpZj0wLHY/KHQu
bGluZVN0YXJ0KCkscD1lKGQsaSksdC5wb2ludChwWzBdLHBbMV0pKToocD1lKGksZCksdC5wb2lu
dChwWzBdLHBbMV0pLHQubGluZUVuZCgpKSxpPXA7ZWxzZSBpZihhJiZpJiZ1XnYpe3ZhciBfO2cm
b3x8IShfPWUoZCxpLCEwKSl8fChmPTAsdT8odC5saW5lU3RhcnQoKSx0LnBvaW50KF9bMF1bMF0s
X1swXVsxXSksdC5wb2ludChfWzFdWzBdLF9bMV1bMV0pLHQubGluZUVuZCgpKToodC5wb2ludChf
WzFdWzBdLF9bMV1bMV0pLHQubGluZUVuZCgpLHQubGluZVN0YXJ0KCksdC5wb2ludChfWzBdWzBd
LF9bMF1bMV0pKSl9IXZ8fGkmJkhyKGksZCl8fHQucG9pbnQoZFswXSxkWzFdKSxpPWQsYz12LG89
Z30sbGluZUVuZDpmdW5jdGlvbigpe2MmJnQubGluZUVuZCgpLGk9bnVsbH0sY2xlYW46ZnVuY3Rp
b24oKXtyZXR1cm4gZnwocyYmYyk8PDF9fX0sZnVuY3Rpb24obixlLHIsaSl7SXIoaSx0LG8scixu
LGUpfSx1P1swLC10XTpbLU5wLHQtTnBdKX1mdW5jdGlvbiBKcih0LG4sZSxyKXtmdW5jdGlvbiBp
KGksbyl7cmV0dXJuIHQ8PWkmJmk8PWUmJm48PW8mJm88PXJ9ZnVuY3Rpb24gbyhpLG8sYSxzKXt2
YXIgZj0wLGw9MDtpZihudWxsPT1pfHwoZj11KGksYSkpIT09KGw9dShvLGEpKXx8YyhpLG8pPDBe
YT4wKWRve3MucG9pbnQoMD09PWZ8fDM9PT1mP3Q6ZSxmPjE/cjpuKX13aGlsZSgoZj0oZithKzQp
JTQpIT09bCk7ZWxzZSBzLnBvaW50KG9bMF0sb1sxXSl9ZnVuY3Rpb24gdShyLGkpe3JldHVybiB6
cChyWzBdLXQpPE1wP2k+MD8wOjM6enAoclswXS1lKTxNcD9pPjA/MjoxOnpwKHJbMV0tbik8TXA/
aT4wPzE6MDppPjA/MzoyfWZ1bmN0aW9uIGEodCxuKXtyZXR1cm4gYyh0Lngsbi54KX1mdW5jdGlv
biBjKHQsbil7dmFyIGU9dSh0LDEpLHI9dShuLDEpO3JldHVybiBlIT09cj9lLXI6MD09PWU/blsx
XS10WzFdOjE9PT1lP3RbMF0tblswXToyPT09ZT90WzFdLW5bMV06blswXS10WzBdfXJldHVybiBm
dW5jdGlvbih1KXtmdW5jdGlvbiBjKHQsbil7aSh0LG4pJiZ3LnBvaW50KHQsbil9ZnVuY3Rpb24g
cyhvLHUpe3ZhciBhPWkobyx1KTtpZihsJiZoLnB1c2goW28sdV0pLHgpcD1vLGQ9dSx2PWEseD0h
MSxhJiYody5saW5lU3RhcnQoKSx3LnBvaW50KG8sdSkpO2Vsc2UgaWYoYSYmbSl3LnBvaW50KG8s
dSk7ZWxzZXt2YXIgYz1bXz1NYXRoLm1heChsZCxNYXRoLm1pbihmZCxfKSkseT1NYXRoLm1heChs
ZCxNYXRoLm1pbihmZCx5KSldLHM9W289TWF0aC5tYXgobGQsTWF0aC5taW4oZmQsbykpLHU9TWF0
aC5tYXgobGQsTWF0aC5taW4oZmQsdSkpXTshZnVuY3Rpb24odCxuLGUscixpLG8pe3ZhciB1LGE9
dFswXSxjPXRbMV0scz0wLGY9MSxsPW5bMF0tYSxoPW5bMV0tYztpZih1PWUtYSxsfHwhKHU+MCkp
e2lmKHUvPWwsbDwwKXtpZih1PHMpcmV0dXJuO3U8ZiYmKGY9dSl9ZWxzZSBpZihsPjApe2lmKHU+
ZilyZXR1cm47dT5zJiYocz11KX1pZih1PWktYSxsfHwhKHU8MCkpe2lmKHUvPWwsbDwwKXtpZih1
PmYpcmV0dXJuO3U+cyYmKHM9dSl9ZWxzZSBpZihsPjApe2lmKHU8cylyZXR1cm47dTxmJiYoZj11
KX1pZih1PXItYyxofHwhKHU+MCkpe2lmKHUvPWgsaDwwKXtpZih1PHMpcmV0dXJuO3U8ZiYmKGY9
dSl9ZWxzZSBpZihoPjApe2lmKHU+ZilyZXR1cm47dT5zJiYocz11KX1pZih1PW8tYyxofHwhKHU8
MCkpe2lmKHUvPWgsaDwwKXtpZih1PmYpcmV0dXJuO3U+cyYmKHM9dSl9ZWxzZSBpZihoPjApe2lm
KHU8cylyZXR1cm47dTxmJiYoZj11KX1yZXR1cm4gcz4wJiYodFswXT1hK3MqbCx0WzFdPWMrcypo
KSxmPDEmJihuWzBdPWErZipsLG5bMV09YytmKmgpLCEwfX19fX0oYyxzLHQsbixlLHIpP2EmJih3
LmxpbmVTdGFydCgpLHcucG9pbnQobyx1KSxiPSExKToobXx8KHcubGluZVN0YXJ0KCksdy5wb2lu
dChjWzBdLGNbMV0pKSx3LnBvaW50KHNbMF0sc1sxXSksYXx8dy5saW5lRW5kKCksYj0hMSl9Xz1v
LHk9dSxtPWF9dmFyIGYsbCxoLHAsZCx2LF8seSxtLHgsYix3PXUsTT1CcigpLFQ9e3BvaW50OmMs
bGluZVN0YXJ0OmZ1bmN0aW9uKCl7VC5wb2ludD1zLGwmJmwucHVzaChoPVtdKSx4PSEwLG09ITEs
Xz15PU5hTn0sbGluZUVuZDpmdW5jdGlvbigpe2YmJihzKHAsZCksdiYmbSYmTS5yZWpvaW4oKSxm
LnB1c2goTS5yZXN1bHQoKSkpLFQucG9pbnQ9YyxtJiZ3LmxpbmVFbmQoKX0scG9seWdvblN0YXJ0
OmZ1bmN0aW9uKCl7dz1NLGY9W10sbD1bXSxiPSEwfSxwb2x5Z29uRW5kOmZ1bmN0aW9uKCl7dmFy
IG49ZnVuY3Rpb24oKXtmb3IodmFyIG49MCxlPTAsaT1sLmxlbmd0aDtlPGk7KytlKWZvcih2YXIg
byx1LGE9bFtlXSxjPTEscz1hLmxlbmd0aCxmPWFbMF0saD1mWzBdLHA9ZlsxXTtjPHM7KytjKW89
aCx1PXAsaD0oZj1hW2NdKVswXSxwPWZbMV0sdTw9cj9wPnImJihoLW8pKihyLXUpPihwLXUpKih0
LW8pJiYrK246cDw9ciYmKGgtbykqKHItdSk8KHAtdSkqKHQtbykmJi0tbjtyZXR1cm4gbn0oKSxl
PWImJm4saT0oZj1nKGYpKS5sZW5ndGg7KGV8fGkpJiYodS5wb2x5Z29uU3RhcnQoKSxlJiYodS5s
aW5lU3RhcnQoKSxvKG51bGwsbnVsbCwxLHUpLHUubGluZUVuZCgpKSxpJiZYcihmLGEsbixvLHUp
LHUucG9seWdvbkVuZCgpKSx3PXUsZj1sPWg9bnVsbH19O3JldHVybiBUfX1mdW5jdGlvbiBLcigp
e3BkLnBvaW50PXBkLmxpbmVFbmQ9R2V9ZnVuY3Rpb24gdGkodCxuKXtRcD10Kj1DcCxKcD1GcChu
Kj1DcCksS3A9THAobikscGQucG9pbnQ9bml9ZnVuY3Rpb24gbmkodCxuKXt0Kj1DcDt2YXIgZT1G
cChuKj1DcCkscj1McChuKSxpPXpwKHQtUXApLG89THAoaSksdT1yKkZwKGkpLGE9S3AqZS1KcCpy
Km8sYz1KcCplK0twKnIqbztoZC5hZGQoUnAoWXAodSp1K2EqYSksYykpLFFwPXQsSnA9ZSxLcD1y
fWZ1bmN0aW9uIGVpKHQpe3JldHVybiBoZC5yZXNldCgpLHRyKHQscGQpLCtoZH1mdW5jdGlvbiBy
aSh0LG4pe3JldHVybiBkZFswXT10LGRkWzFdPW4sZWkodmQpfWZ1bmN0aW9uIGlpKHQsbil7cmV0
dXJuISghdHx8IV9kLmhhc093blByb3BlcnR5KHQudHlwZSkpJiZfZFt0LnR5cGVdKHQsbil9ZnVu
Y3Rpb24gb2kodCxuKXtyZXR1cm4gMD09PXJpKHQsbil9ZnVuY3Rpb24gdWkodCxuKXt2YXIgZT1y
aSh0WzBdLHRbMV0pO3JldHVybiByaSh0WzBdLG4pK3JpKG4sdFsxXSk8PWUrTXB9ZnVuY3Rpb24g
YWkodCxuKXtyZXR1cm4hISRyKHQubWFwKGNpKSxzaShuKSl9ZnVuY3Rpb24gY2kodCl7cmV0dXJu
KHQ9dC5tYXAoc2kpKS5wb3AoKSx0fWZ1bmN0aW9uIHNpKHQpe3JldHVyblt0WzBdKkNwLHRbMV0q
Q3BdfWZ1bmN0aW9uIGZpKHQsbixlKXt2YXIgcj1mKHQsbi1NcCxlKS5jb25jYXQobik7cmV0dXJu
IGZ1bmN0aW9uKHQpe3JldHVybiByLm1hcChmdW5jdGlvbihuKXtyZXR1cm5bdCxuXX0pfX1mdW5j
dGlvbiBsaSh0LG4sZSl7dmFyIHI9Zih0LG4tTXAsZSkuY29uY2F0KG4pO3JldHVybiBmdW5jdGlv
bih0KXtyZXR1cm4gci5tYXAoZnVuY3Rpb24obil7cmV0dXJuW24sdF19KX19ZnVuY3Rpb24gaGko
KXtmdW5jdGlvbiB0KCl7cmV0dXJue3R5cGU6Ik11bHRpTGluZVN0cmluZyIsY29vcmRpbmF0ZXM6
bigpfX1mdW5jdGlvbiBuKCl7cmV0dXJuIGYocXAoby9fKSpfLGksXykubWFwKHApLmNvbmNhdChm
KHFwKHMveSkqeSxjLHkpLm1hcChkKSkuY29uY2F0KGYocXAoci92KSp2LGUsdikuZmlsdGVyKGZ1
bmN0aW9uKHQpe3JldHVybiB6cCh0JV8pPk1wfSkubWFwKGwpKS5jb25jYXQoZihxcChhL2cpKmcs
dSxnKS5maWx0ZXIoZnVuY3Rpb24odCl7cmV0dXJuIHpwKHQleSk+TXB9KS5tYXAoaCkpfXZhciBl
LHIsaSxvLHUsYSxjLHMsbCxoLHAsZCx2PTEwLGc9dixfPTkwLHk9MzYwLG09Mi41O3JldHVybiB0
LmxpbmVzPWZ1bmN0aW9uKCl7cmV0dXJuIG4oKS5tYXAoZnVuY3Rpb24odCl7cmV0dXJue3R5cGU6
IkxpbmVTdHJpbmciLGNvb3JkaW5hdGVzOnR9fSl9LHQub3V0bGluZT1mdW5jdGlvbigpe3JldHVy
bnt0eXBlOiJQb2x5Z29uIixjb29yZGluYXRlczpbcChvKS5jb25jYXQoZChjKS5zbGljZSgxKSxw
KGkpLnJldmVyc2UoKS5zbGljZSgxKSxkKHMpLnJldmVyc2UoKS5zbGljZSgxKSldfX0sdC5leHRl
bnQ9ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/dC5leHRlbnRNYWpvcihuKS5l
eHRlbnRNaW5vcihuKTp0LmV4dGVudE1pbm9yKCl9LHQuZXh0ZW50TWFqb3I9ZnVuY3Rpb24obil7
cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KG89K25bMF1bMF0saT0rblsxXVswXSxzPStuWzBdWzFd
LGM9K25bMV1bMV0sbz5pJiYobj1vLG89aSxpPW4pLHM+YyYmKG49cyxzPWMsYz1uKSx0LnByZWNp
c2lvbihtKSk6W1tvLHNdLFtpLGNdXX0sdC5leHRlbnRNaW5vcj1mdW5jdGlvbihuKXtyZXR1cm4g
YXJndW1lbnRzLmxlbmd0aD8ocj0rblswXVswXSxlPStuWzFdWzBdLGE9K25bMF1bMV0sdT0rblsx
XVsxXSxyPmUmJihuPXIscj1lLGU9biksYT51JiYobj1hLGE9dSx1PW4pLHQucHJlY2lzaW9uKG0p
KTpbW3IsYV0sW2UsdV1dfSx0LnN0ZXA9ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5sZW5n
dGg/dC5zdGVwTWFqb3Iobikuc3RlcE1pbm9yKG4pOnQuc3RlcE1pbm9yKCl9LHQuc3RlcE1ham9y
PWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhfPStuWzBdLHk9K25bMV0sdCk6
W18seV19LHQuc3RlcE1pbm9yPWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyh2
PStuWzBdLGc9K25bMV0sdCk6W3YsZ119LHQucHJlY2lzaW9uPWZ1bmN0aW9uKG4pe3JldHVybiBh
cmd1bWVudHMubGVuZ3RoPyhtPStuLGw9ZmkoYSx1LDkwKSxoPWxpKHIsZSxtKSxwPWZpKHMsYyw5
MCksZD1saShvLGksbSksdCk6bX0sdC5leHRlbnRNYWpvcihbWy0xODAsLTkwK01wXSxbMTgwLDkw
LU1wXV0pLmV4dGVudE1pbm9yKFtbLTE4MCwtODAtTXBdLFsxODAsODArTXBdXSl9ZnVuY3Rpb24g
cGkodCl7cmV0dXJuIHR9ZnVuY3Rpb24gZGkoKXt4ZC5wb2ludD12aX1mdW5jdGlvbiB2aSh0LG4p
e3hkLnBvaW50PWdpLHRkPWVkPXQsbmQ9cmQ9bn1mdW5jdGlvbiBnaSh0LG4pe21kLmFkZChyZCp0
LWVkKm4pLGVkPXQscmQ9bn1mdW5jdGlvbiBfaSgpe2dpKHRkLG5kKX1mdW5jdGlvbiB5aSh0LG4p
e2tkKz10LFNkKz1uLCsrRWR9ZnVuY3Rpb24gbWkoKXtxZC5wb2ludD14aX1mdW5jdGlvbiB4aSh0
LG4pe3FkLnBvaW50PWJpLHlpKHVkPXQsYWQ9bil9ZnVuY3Rpb24gYmkodCxuKXt2YXIgZT10LXVk
LHI9bi1hZCxpPVlwKGUqZStyKnIpO0FkKz1pKih1ZCt0KS8yLENkKz1pKihhZCtuKS8yLHpkKz1p
LHlpKHVkPXQsYWQ9bil9ZnVuY3Rpb24gd2koKXtxZC5wb2ludD15aX1mdW5jdGlvbiBNaSgpe3Fk
LnBvaW50PU5pfWZ1bmN0aW9uIFRpKCl7a2koaWQsb2QpfWZ1bmN0aW9uIE5pKHQsbil7cWQucG9p
bnQ9a2kseWkoaWQ9dWQ9dCxvZD1hZD1uKX1mdW5jdGlvbiBraSh0LG4pe3ZhciBlPXQtdWQscj1u
LWFkLGk9WXAoZSplK3Iqcik7QWQrPWkqKHVkK3QpLzIsQ2QrPWkqKGFkK24pLzIsemQrPWksUGQr
PShpPWFkKnQtdWQqbikqKHVkK3QpLFJkKz1pKihhZCtuKSxMZCs9MyppLHlpKHVkPXQsYWQ9bil9
ZnVuY3Rpb24gU2kodCl7dGhpcy5fY29udGV4dD10fWZ1bmN0aW9uIEVpKHQsbil7QmQucG9pbnQ9
QWksVWQ9RmQ9dCxPZD1JZD1ufWZ1bmN0aW9uIEFpKHQsbil7RmQtPXQsSWQtPW4sWWQuYWRkKFlw
KEZkKkZkK0lkKklkKSksRmQ9dCxJZD1ufWZ1bmN0aW9uIENpKCl7dGhpcy5fc3RyaW5nPVtdfWZ1
bmN0aW9uIHppKHQpe3JldHVybiJtMCwiK3QrImEiK3QrIiwiK3QrIiAwIDEsMSAwLCIrLTIqdCsi
YSIrdCsiLCIrdCsiIDAgMSwxIDAsIisyKnQrInoifWZ1bmN0aW9uIFBpKHQpe3JldHVybiBmdW5j
dGlvbihuKXt2YXIgZT1uZXcgUmk7Zm9yKHZhciByIGluIHQpZVtyXT10W3JdO3JldHVybiBlLnN0
cmVhbT1uLGV9fWZ1bmN0aW9uIFJpKCl7fWZ1bmN0aW9uIExpKHQsbixlKXt2YXIgcj10LmNsaXBF
eHRlbnQmJnQuY2xpcEV4dGVudCgpO3JldHVybiB0LnNjYWxlKDE1MCkudHJhbnNsYXRlKFswLDBd
KSxudWxsIT1yJiZ0LmNsaXBFeHRlbnQobnVsbCksdHIoZSx0LnN0cmVhbShOZCkpLG4oTmQucmVz
dWx0KCkpLG51bGwhPXImJnQuY2xpcEV4dGVudChyKSx0fWZ1bmN0aW9uIHFpKHQsbixlKXtyZXR1
cm4gTGkodCxmdW5jdGlvbihlKXt2YXIgcj1uWzFdWzBdLW5bMF1bMF0saT1uWzFdWzFdLW5bMF1b
MV0sbz1NYXRoLm1pbihyLyhlWzFdWzBdLWVbMF1bMF0pLGkvKGVbMV1bMV0tZVswXVsxXSkpLHU9
K25bMF1bMF0rKHItbyooZVsxXVswXStlWzBdWzBdKSkvMixhPStuWzBdWzFdKyhpLW8qKGVbMV1b
MV0rZVswXVsxXSkpLzI7dC5zY2FsZSgxNTAqbykudHJhbnNsYXRlKFt1LGFdKX0sZSl9ZnVuY3Rp
b24gRGkodCxuLGUpe3JldHVybiBxaSh0LFtbMCwwXSxuXSxlKX1mdW5jdGlvbiBVaSh0LG4sZSl7
cmV0dXJuIExpKHQsZnVuY3Rpb24oZSl7dmFyIHI9K24saT1yLyhlWzFdWzBdLWVbMF1bMF0pLG89
KHItaSooZVsxXVswXStlWzBdWzBdKSkvMix1PS1pKmVbMF1bMV07dC5zY2FsZSgxNTAqaSkudHJh
bnNsYXRlKFtvLHVdKX0sZSl9ZnVuY3Rpb24gT2kodCxuLGUpe3JldHVybiBMaSh0LGZ1bmN0aW9u
KGUpe3ZhciByPStuLGk9ci8oZVsxXVsxXS1lWzBdWzFdKSxvPS1pKmVbMF1bMF0sdT0oci1pKihl
WzFdWzFdK2VbMF1bMV0pKS8yO3Quc2NhbGUoMTUwKmkpLnRyYW5zbGF0ZShbbyx1XSl9LGUpfWZ1
bmN0aW9uIEZpKHQsbil7cmV0dXJuK24/ZnVuY3Rpb24odCxuKXtmdW5jdGlvbiBlKHIsaSxvLHUs
YSxjLHMsZixsLGgscCxkLHYsZyl7dmFyIF89cy1yLHk9Zi1pLG09XypfK3kqeTtpZihtPjQqbiYm
di0tKXt2YXIgeD11K2gsYj1hK3Asdz1jK2QsTT1ZcCh4KngrYipiK3cqdyksVD1XZSh3Lz1NKSxO
PXpwKHpwKHcpLTEpPE1wfHx6cChvLWwpPE1wPyhvK2wpLzI6UnAoYix4KSxrPXQoTixUKSxTPWtb
MF0sRT1rWzFdLEE9Uy1yLEM9RS1pLHo9eSpBLV8qQzsoeip6L20+bnx8enAoKF8qQSt5KkMpL20t
LjUpPi4zfHx1KmgrYSpwK2MqZDxqZCkmJihlKHIsaSxvLHUsYSxjLFMsRSxOLHgvPU0sYi89TSx3
LHYsZyksZy5wb2ludChTLEUpLGUoUyxFLE4seCxiLHcscyxmLGwsaCxwLGQsdixnKSl9fXJldHVy
biBmdW5jdGlvbihuKXtmdW5jdGlvbiByKGUscil7ZT10KGUsciksbi5wb2ludChlWzBdLGVbMV0p
fWZ1bmN0aW9uIGkoKXtfPU5hTix3LnBvaW50PW8sbi5saW5lU3RhcnQoKX1mdW5jdGlvbiBvKHIs
aSl7dmFyIG89dXIoW3IsaV0pLHU9dChyLGkpO2UoXyx5LGcsbSx4LGIsXz11WzBdLHk9dVsxXSxn
PXIsbT1vWzBdLHg9b1sxXSxiPW9bMl0sSGQsbiksbi5wb2ludChfLHkpfWZ1bmN0aW9uIHUoKXt3
LnBvaW50PXIsbi5saW5lRW5kKCl9ZnVuY3Rpb24gYSgpe2koKSx3LnBvaW50PWMsdy5saW5lRW5k
PXN9ZnVuY3Rpb24gYyh0LG4pe28oZj10LG4pLGw9XyxoPXkscD1tLGQ9eCx2PWIsdy5wb2ludD1v
fWZ1bmN0aW9uIHMoKXtlKF8seSxnLG0seCxiLGwsaCxmLHAsZCx2LEhkLG4pLHcubGluZUVuZD11
LHUoKX12YXIgZixsLGgscCxkLHYsZyxfLHksbSx4LGIsdz17cG9pbnQ6cixsaW5lU3RhcnQ6aSxs
aW5lRW5kOnUscG9seWdvblN0YXJ0OmZ1bmN0aW9uKCl7bi5wb2x5Z29uU3RhcnQoKSx3LmxpbmVT
dGFydD1hfSxwb2x5Z29uRW5kOmZ1bmN0aW9uKCl7bi5wb2x5Z29uRW5kKCksdy5saW5lU3RhcnQ9
aX19O3JldHVybiB3fX0odCxuKTpmdW5jdGlvbih0KXtyZXR1cm4gUGkoe3BvaW50OmZ1bmN0aW9u
KG4sZSl7bj10KG4sZSksdGhpcy5zdHJlYW0ucG9pbnQoblswXSxuWzFdKX19KX0odCl9ZnVuY3Rp
b24gSWkodCl7cmV0dXJuIFlpKGZ1bmN0aW9uKCl7cmV0dXJuIHR9KSgpfWZ1bmN0aW9uIFlpKHQp
e2Z1bmN0aW9uIG4odCl7cmV0dXJuIHQ9cyh0WzBdKkNwLHRbMV0qQ3ApLFt0WzBdKnYrdSxhLXRb
MV0qdl19ZnVuY3Rpb24gZSh0LG4pe3JldHVybiB0PW8odCxuKSxbdFswXSp2K3UsYS10WzFdKnZd
fWZ1bmN0aW9uIHIoKXtzPVJyKGM9cXIoeCxiLHcpLG8pO3ZhciB0PW8oeSxtKTtyZXR1cm4gdT1n
LXRbMF0qdixhPV8rdFsxXSp2LGkoKX1mdW5jdGlvbiBpKCl7cmV0dXJuIHA9ZD1udWxsLG59dmFy
IG8sdSxhLGMscyxmLGwsaCxwLGQsdj0xNTAsZz00ODAsXz0yNTAseT0wLG09MCx4PTAsYj0wLHc9
MCxNPW51bGwsVD1zZCxOPW51bGwsaz1waSxTPS41LEU9RmkoZSxTKTtyZXR1cm4gbi5zdHJlYW09
ZnVuY3Rpb24odCl7cmV0dXJuIHAmJmQ9PT10P3A6cD1YZChmdW5jdGlvbih0KXtyZXR1cm4gUGko
e3BvaW50OmZ1bmN0aW9uKG4sZSl7dmFyIHI9dChuLGUpO3JldHVybiB0aGlzLnN0cmVhbS5wb2lu
dChyWzBdLHJbMV0pfX0pfShjKShUKEUoayhkPXQpKSkpKX0sbi5wcmVjbGlwPWZ1bmN0aW9uKHQp
e3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhUPXQsTT12b2lkIDAsaSgpKTpUfSxuLnBvc3RjbGlw
PWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhrPXQsTj1mPWw9aD1udWxsLGko
KSk6a30sbi5jbGlwQW5nbGU9ZnVuY3Rpb24odCl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KFQ9
K3Q/UXIoTT10KkNwKTooTT1udWxsLHNkKSxpKCkpOk0qQXB9LG4uY2xpcEV4dGVudD1mdW5jdGlv
bih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oaz1udWxsPT10PyhOPWY9bD1oPW51bGwscGkp
OkpyKE49K3RbMF1bMF0sZj0rdFswXVsxXSxsPSt0WzFdWzBdLGg9K3RbMV1bMV0pLGkoKSk6bnVs
bD09Tj9udWxsOltbTixmXSxbbCxoXV19LG4uc2NhbGU9ZnVuY3Rpb24odCl7cmV0dXJuIGFyZ3Vt
ZW50cy5sZW5ndGg/KHY9K3QscigpKTp2fSxuLnRyYW5zbGF0ZT1mdW5jdGlvbih0KXtyZXR1cm4g
YXJndW1lbnRzLmxlbmd0aD8oZz0rdFswXSxfPSt0WzFdLHIoKSk6W2csX119LG4uY2VudGVyPWZ1
bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyh5PXRbMF0lMzYwKkNwLG09dFsxXSUz
NjAqQ3AscigpKTpbeSpBcCxtKkFwXX0sbi5yb3RhdGU9ZnVuY3Rpb24odCl7cmV0dXJuIGFyZ3Vt
ZW50cy5sZW5ndGg/KHg9dFswXSUzNjAqQ3AsYj10WzFdJTM2MCpDcCx3PXQubGVuZ3RoPjI/dFsy
XSUzNjAqQ3A6MCxyKCkpOlt4KkFwLGIqQXAsdypBcF19LG4ucHJlY2lzaW9uPWZ1bmN0aW9uKHQp
e3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhFPUZpKGUsUz10KnQpLGkoKSk6WXAoUyl9LG4uZml0
RXh0ZW50PWZ1bmN0aW9uKHQsZSl7cmV0dXJuIHFpKG4sdCxlKX0sbi5maXRTaXplPWZ1bmN0aW9u
KHQsZSl7cmV0dXJuIERpKG4sdCxlKX0sbi5maXRXaWR0aD1mdW5jdGlvbih0LGUpe3JldHVybiBV
aShuLHQsZSl9LG4uZml0SGVpZ2h0PWZ1bmN0aW9uKHQsZSl7cmV0dXJuIE9pKG4sdCxlKX0sZnVu
Y3Rpb24oKXtyZXR1cm4gbz10LmFwcGx5KHRoaXMsYXJndW1lbnRzKSxuLmludmVydD1vLmludmVy
dCYmZnVuY3Rpb24odCl7cmV0dXJuKHQ9cy5pbnZlcnQoKHRbMF0tdSkvdiwoYS10WzFdKS92KSkm
Jlt0WzBdKkFwLHRbMV0qQXBdfSxyKCl9fWZ1bmN0aW9uIEJpKHQpe3ZhciBuPTAsZT1OcC8zLHI9
WWkodCksaT1yKG4sZSk7cmV0dXJuIGkucGFyYWxsZWxzPWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1
bWVudHMubGVuZ3RoP3Iobj10WzBdKkNwLGU9dFsxXSpDcCk6W24qQXAsZSpBcF19LGl9ZnVuY3Rp
b24gSGkodCxuKXtmdW5jdGlvbiBlKHQsbil7dmFyIGU9WXAoby0yKmkqRnAobikpL2k7cmV0dXJu
W2UqRnAodCo9aSksdS1lKkxwKHQpXX12YXIgcj1GcCh0KSxpPShyK0ZwKG4pKS8yO2lmKHpwKGkp
PE1wKXJldHVybiBmdW5jdGlvbih0KXtmdW5jdGlvbiBuKHQsbil7cmV0dXJuW3QqZSxGcChuKS9l
XX12YXIgZT1McCh0KTtyZXR1cm4gbi5pbnZlcnQ9ZnVuY3Rpb24odCxuKXtyZXR1cm5bdC9lLFdl
KG4qZSldfSxufSh0KTt2YXIgbz0xK3IqKDIqaS1yKSx1PVlwKG8pL2k7cmV0dXJuIGUuaW52ZXJ0
PWZ1bmN0aW9uKHQsbil7dmFyIGU9dS1uO3JldHVybltScCh0LHpwKGUpKS9pKklwKGUpLFdlKChv
LSh0KnQrZSplKSppKmkpLygyKmkpKV19LGV9ZnVuY3Rpb24gamkoKXtyZXR1cm4gQmkoSGkpLnNj
YWxlKDE1NS40MjQpLmNlbnRlcihbMCwzMy42NDQyXSl9ZnVuY3Rpb24gWGkoKXtyZXR1cm4gamko
KS5wYXJhbGxlbHMoWzI5LjUsNDUuNV0pLnNjYWxlKDEwNzApLnRyYW5zbGF0ZShbNDgwLDI1MF0p
LnJvdGF0ZShbOTYsMF0pLmNlbnRlcihbLS42LDM4LjddKX1mdW5jdGlvbiBWaSh0KXtyZXR1cm4g
ZnVuY3Rpb24obixlKXt2YXIgcj1McChuKSxpPUxwKGUpLG89dChyKmkpO3JldHVybltvKmkqRnAo
biksbypGcChlKV19fWZ1bmN0aW9uICRpKHQpe3JldHVybiBmdW5jdGlvbihuLGUpe3ZhciByPVlw
KG4qbitlKmUpLGk9dChyKSxvPUZwKGkpLHU9THAoaSk7cmV0dXJuW1JwKG4qbyxyKnUpLFdlKHIm
JmUqby9yKV19fWZ1bmN0aW9uIFdpKHQsbil7cmV0dXJuW3QsVXAoQnAoKGtwK24pLzIpKV19ZnVu
Y3Rpb24gWmkodCl7ZnVuY3Rpb24gbigpe3ZhciBuPU5wKmEoKSx1PW8oRnIoby5yb3RhdGUoKSku
aW52ZXJ0KFswLDBdKSk7cmV0dXJuIHMobnVsbD09Zj9bW3VbMF0tbix1WzFdLW5dLFt1WzBdK24s
dVsxXStuXV06dD09PVdpP1tbTWF0aC5tYXgodVswXS1uLGYpLGVdLFtNYXRoLm1pbih1WzBdK24s
ciksaV1dOltbZixNYXRoLm1heCh1WzFdLW4sZSldLFtyLE1hdGgubWluKHVbMV0rbixpKV1dKX12
YXIgZSxyLGksbz1JaSh0KSx1PW8uY2VudGVyLGE9by5zY2FsZSxjPW8udHJhbnNsYXRlLHM9by5j
bGlwRXh0ZW50LGY9bnVsbDtyZXR1cm4gby5zY2FsZT1mdW5jdGlvbih0KXtyZXR1cm4gYXJndW1l
bnRzLmxlbmd0aD8oYSh0KSxuKCkpOmEoKX0sby50cmFuc2xhdGU9ZnVuY3Rpb24odCl7cmV0dXJu
IGFyZ3VtZW50cy5sZW5ndGg/KGModCksbigpKTpjKCl9LG8uY2VudGVyPWZ1bmN0aW9uKHQpe3Jl
dHVybiBhcmd1bWVudHMubGVuZ3RoPyh1KHQpLG4oKSk6dSgpfSxvLmNsaXBFeHRlbnQ9ZnVuY3Rp
b24odCl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KG51bGw9PXQ/Zj1lPXI9aT1udWxsOihmPSt0
WzBdWzBdLGU9K3RbMF1bMV0scj0rdFsxXVswXSxpPSt0WzFdWzFdKSxuKCkpOm51bGw9PWY/bnVs
bDpbW2YsZV0sW3IsaV1dfSxuKCl9ZnVuY3Rpb24gR2kodCl7cmV0dXJuIEJwKChrcCt0KS8yKX1m
dW5jdGlvbiBRaSh0LG4pe2Z1bmN0aW9uIGUodCxuKXtvPjA/bjwta3ArTXAmJihuPS1rcCtNcCk6
bj5rcC1NcCYmKG49a3AtTXApO3ZhciBlPW8vT3AoR2kobiksaSk7cmV0dXJuW2UqRnAoaSp0KSxv
LWUqTHAoaSp0KV19dmFyIHI9THAodCksaT10PT09bj9GcCh0KTpVcChyL0xwKG4pKS9VcChHaShu
KS9HaSh0KSksbz1yKk9wKEdpKHQpLGkpL2k7cmV0dXJuIGk/KGUuaW52ZXJ0PWZ1bmN0aW9uKHQs
bil7dmFyIGU9by1uLHI9SXAoaSkqWXAodCp0K2UqZSk7cmV0dXJuW1JwKHQsenAoZSkpL2kqSXAo
ZSksMipQcChPcChvL3IsMS9pKSkta3BdfSxlKTpXaX1mdW5jdGlvbiBKaSh0LG4pe3JldHVyblt0
LG5dfWZ1bmN0aW9uIEtpKHQsbil7ZnVuY3Rpb24gZSh0LG4pe3ZhciBlPW8tbixyPWkqdDtyZXR1
cm5bZSpGcChyKSxvLWUqTHAocildfXZhciByPUxwKHQpLGk9dD09PW4/RnAodCk6KHItTHAobikp
LyhuLXQpLG89ci9pK3Q7cmV0dXJuIHpwKGkpPE1wP0ppOihlLmludmVydD1mdW5jdGlvbih0LG4p
e3ZhciBlPW8tbjtyZXR1cm5bUnAodCx6cChlKSkvaSpJcChlKSxvLUlwKGkpKllwKHQqdCtlKmUp
XX0sZSl9ZnVuY3Rpb24gdG8odCxuKXt2YXIgZT1McChuKSxyPUxwKHQpKmU7cmV0dXJuW2UqRnAo
dCkvcixGcChuKS9yXX1mdW5jdGlvbiBubyh0LG4sZSxyKXtyZXR1cm4gMT09PXQmJjE9PT1uJiYw
PT09ZSYmMD09PXI/cGk6UGkoe3BvaW50OmZ1bmN0aW9uKGksbyl7dGhpcy5zdHJlYW0ucG9pbnQo
aSp0K2UsbypuK3IpfX0pfWZ1bmN0aW9uIGVvKHQsbil7dmFyIGU9bipuLHI9ZSplO3JldHVyblt0
KiguODcwNy0uMTMxOTc5KmUrcioociooLjAwMzk3MSplLS4wMDE1MjkqciktLjAxMzc5MSkpLG4q
KDEuMDA3MjI2K2UqKC4wMTUwODUrciooLjAyODg3NCplLS4wNDQ0NzUtLjAwNTkxNipyKSkpXX1m
dW5jdGlvbiBybyh0LG4pe3JldHVybltMcChuKSpGcCh0KSxGcChuKV19ZnVuY3Rpb24gaW8odCxu
KXt2YXIgZT1McChuKSxyPTErTHAodCkqZTtyZXR1cm5bZSpGcCh0KS9yLEZwKG4pL3JdfWZ1bmN0
aW9uIG9vKHQsbil7cmV0dXJuW1VwKEJwKChrcCtuKS8yKSksLXRdfWZ1bmN0aW9uIHVvKHQsbil7
cmV0dXJuIHQucGFyZW50PT09bi5wYXJlbnQ/MToyfWZ1bmN0aW9uIGFvKHQsbil7cmV0dXJuIHQr
bi54fWZ1bmN0aW9uIGNvKHQsbil7cmV0dXJuIE1hdGgubWF4KHQsbi55KX1mdW5jdGlvbiBzbyh0
KXt2YXIgbj0wLGU9dC5jaGlsZHJlbixyPWUmJmUubGVuZ3RoO2lmKHIpZm9yKDstLXI+PTA7KW4r
PWVbcl0udmFsdWU7ZWxzZSBuPTE7dC52YWx1ZT1ufWZ1bmN0aW9uIGZvKHQsbil7dmFyIGUscixp
LG8sdSxhPW5ldyB2byh0KSxjPSt0LnZhbHVlJiYoYS52YWx1ZT10LnZhbHVlKSxzPVthXTtmb3Io
bnVsbD09biYmKG49bG8pO2U9cy5wb3AoKTspaWYoYyYmKGUudmFsdWU9K2UuZGF0YS52YWx1ZSks
KGk9bihlLmRhdGEpKSYmKHU9aS5sZW5ndGgpKWZvcihlLmNoaWxkcmVuPW5ldyBBcnJheSh1KSxv
PXUtMTtvPj0wOy0tbylzLnB1c2gocj1lLmNoaWxkcmVuW29dPW5ldyB2byhpW29dKSksci5wYXJl
bnQ9ZSxyLmRlcHRoPWUuZGVwdGgrMTtyZXR1cm4gYS5lYWNoQmVmb3JlKHBvKX1mdW5jdGlvbiBs
byh0KXtyZXR1cm4gdC5jaGlsZHJlbn1mdW5jdGlvbiBobyh0KXt0LmRhdGE9dC5kYXRhLmRhdGF9
ZnVuY3Rpb24gcG8odCl7dmFyIG49MDtkb3t0LmhlaWdodD1ufXdoaWxlKCh0PXQucGFyZW50KSYm
dC5oZWlnaHQ8KytuKX1mdW5jdGlvbiB2byh0KXt0aGlzLmRhdGE9dCx0aGlzLmRlcHRoPXRoaXMu
aGVpZ2h0PTAsdGhpcy5wYXJlbnQ9bnVsbH1mdW5jdGlvbiBnbyh0KXtmb3IodmFyIG4sZSxyPTAs
aT0odD1mdW5jdGlvbih0KXtmb3IodmFyIG4sZSxyPXQubGVuZ3RoO3I7KWU9TWF0aC5yYW5kb20o
KSpyLS18MCxuPXRbcl0sdFtyXT10W2VdLHRbZV09bjtyZXR1cm4gdH0oV2QuY2FsbCh0KSkpLmxl
bmd0aCxvPVtdO3I8aTspbj10W3JdLGUmJnlvKGUsbik/KytyOihlPWZ1bmN0aW9uKHQpe3N3aXRj
aCh0Lmxlbmd0aCl7Y2FzZSAxOnJldHVybiBmdW5jdGlvbih0KXtyZXR1cm57eDp0LngseTp0Lnks
cjp0LnJ9fSh0WzBdKTtjYXNlIDI6cmV0dXJuIHhvKHRbMF0sdFsxXSk7Y2FzZSAzOnJldHVybiBi
byh0WzBdLHRbMV0sdFsyXSl9fShvPWZ1bmN0aW9uKHQsbil7dmFyIGUscjtpZihtbyhuLHQpKXJl
dHVybltuXTtmb3IoZT0wO2U8dC5sZW5ndGg7KytlKWlmKF9vKG4sdFtlXSkmJm1vKHhvKHRbZV0s
biksdCkpcmV0dXJuW3RbZV0sbl07Zm9yKGU9MDtlPHQubGVuZ3RoLTE7KytlKWZvcihyPWUrMTty
PHQubGVuZ3RoOysrcilpZihfbyh4byh0W2VdLHRbcl0pLG4pJiZfbyh4byh0W2VdLG4pLHRbcl0p
JiZfbyh4byh0W3JdLG4pLHRbZV0pJiZtbyhibyh0W2VdLHRbcl0sbiksdCkpcmV0dXJuW3RbZV0s
dFtyXSxuXTt0aHJvdyBuZXcgRXJyb3J9KG8sbikpLHI9MCk7cmV0dXJuIGV9ZnVuY3Rpb24gX28o
dCxuKXt2YXIgZT10LnItbi5yLHI9bi54LXQueCxpPW4ueS10Lnk7cmV0dXJuIGU8MHx8ZSplPHIq
citpKml9ZnVuY3Rpb24geW8odCxuKXt2YXIgZT10LnItbi5yKzFlLTYscj1uLngtdC54LGk9bi55
LXQueTtyZXR1cm4gZT4wJiZlKmU+cipyK2kqaX1mdW5jdGlvbiBtbyh0LG4pe2Zvcih2YXIgZT0w
O2U8bi5sZW5ndGg7KytlKWlmKCF5byh0LG5bZV0pKXJldHVybiExO3JldHVybiEwfWZ1bmN0aW9u
IHhvKHQsbil7dmFyIGU9dC54LHI9dC55LGk9dC5yLG89bi54LHU9bi55LGE9bi5yLGM9by1lLHM9
dS1yLGY9YS1pLGw9TWF0aC5zcXJ0KGMqYytzKnMpO3JldHVybnt4OihlK28rYy9sKmYpLzIseToo
cit1K3MvbCpmKS8yLHI6KGwraSthKS8yfX1mdW5jdGlvbiBibyh0LG4sZSl7dmFyIHI9dC54LGk9
dC55LG89dC5yLHU9bi54LGE9bi55LGM9bi5yLHM9ZS54LGY9ZS55LGw9ZS5yLGg9ci11LHA9ci1z
LGQ9aS1hLHY9aS1mLGc9Yy1vLF89bC1vLHk9cipyK2kqaS1vKm8sbT15LXUqdS1hKmErYypjLHg9
eS1zKnMtZipmK2wqbCxiPXAqZC1oKnYsdz0oZCp4LXYqbSkvKDIqYiktcixNPSh2KmctZCpfKS9i
LFQ9KHAqbS1oKngpLygyKmIpLWksTj0oaCpfLXAqZykvYixrPU0qTStOKk4tMSxTPTIqKG8rdypN
K1QqTiksRT13KncrVCpULW8qbyxBPS0oaz8oUytNYXRoLnNxcnQoUypTLTQqaypFKSkvKDIqayk6
RS9TKTtyZXR1cm57eDpyK3crTSpBLHk6aStUK04qQSxyOkF9fWZ1bmN0aW9uIHdvKHQsbixlKXt2
YXIgcj10LngsaT10Lnksbz1uLnIrZS5yLHU9dC5yK2UucixhPW4ueC1yLGM9bi55LWkscz1hKmEr
YypjO2lmKHMpe3ZhciBmPS41KygodSo9dSktKG8qPW8pKS8oMipzKSxsPU1hdGguc3FydChNYXRo
Lm1heCgwLDIqbyoodStzKS0odS09cykqdS1vKm8pKS8oMipzKTtlLng9citmKmErbCpjLGUueT1p
K2YqYy1sKmF9ZWxzZSBlLng9cit1LGUueT1pfWZ1bmN0aW9uIE1vKHQsbil7dmFyIGU9bi54LXQu
eCxyPW4ueS10LnksaT10LnIrbi5yO3JldHVybiBpKmktMWUtNj5lKmUrcipyfWZ1bmN0aW9uIFRv
KHQpe3ZhciBuPXQuXyxlPXQubmV4dC5fLHI9bi5yK2UucixpPShuLngqZS5yK2UueCpuLnIpL3Is
bz0obi55KmUucitlLnkqbi5yKS9yO3JldHVybiBpKmkrbypvfWZ1bmN0aW9uIE5vKHQpe3RoaXMu
Xz10LHRoaXMubmV4dD1udWxsLHRoaXMucHJldmlvdXM9bnVsbH1mdW5jdGlvbiBrbyh0KXtpZigh
KGk9dC5sZW5ndGgpKXJldHVybiAwO3ZhciBuLGUscixpLG8sdSxhLGMscyxmLGw7aWYobj10WzBd
LG4ueD0wLG4ueT0wLCEoaT4xKSlyZXR1cm4gbi5yO2lmKGU9dFsxXSxuLng9LWUucixlLng9bi5y
LGUueT0wLCEoaT4yKSlyZXR1cm4gbi5yK2Uucjt3byhlLG4scj10WzJdKSxuPW5ldyBObyhuKSxl
PW5ldyBObyhlKSxyPW5ldyBObyhyKSxuLm5leHQ9ci5wcmV2aW91cz1lLGUubmV4dD1uLnByZXZp
b3VzPXIsci5uZXh0PWUucHJldmlvdXM9bjt0OmZvcihhPTM7YTxpOysrYSl7d28obi5fLGUuXyxy
PXRbYV0pLHI9bmV3IE5vKHIpLGM9ZS5uZXh0LHM9bi5wcmV2aW91cyxmPWUuXy5yLGw9bi5fLnI7
ZG97aWYoZjw9bCl7aWYoTW8oYy5fLHIuXykpe2U9YyxuLm5leHQ9ZSxlLnByZXZpb3VzPW4sLS1h
O2NvbnRpbnVlIHR9Zis9Yy5fLnIsYz1jLm5leHR9ZWxzZXtpZihNbyhzLl8sci5fKSl7KG49cyku
bmV4dD1lLGUucHJldmlvdXM9biwtLWE7Y29udGludWUgdH1sKz1zLl8ucixzPXMucHJldmlvdXN9
fXdoaWxlKGMhPT1zLm5leHQpO2ZvcihyLnByZXZpb3VzPW4sci5uZXh0PWUsbi5uZXh0PWUucHJl
dmlvdXM9ZT1yLG89VG8obik7KHI9ci5uZXh0KSE9PWU7KSh1PVRvKHIpKTxvJiYobj1yLG89dSk7
ZT1uLm5leHR9Zm9yKG49W2UuX10scj1lOyhyPXIubmV4dCkhPT1lOyluLnB1c2goci5fKTtmb3Io
cj1nbyhuKSxhPTA7YTxpOysrYSluPXRbYV0sbi54LT1yLngsbi55LT1yLnk7cmV0dXJuIHIucn1m
dW5jdGlvbiBTbyh0KXtpZigiZnVuY3Rpb24iIT10eXBlb2YgdCl0aHJvdyBuZXcgRXJyb3I7cmV0
dXJuIHR9ZnVuY3Rpb24gRW8oKXtyZXR1cm4gMH1mdW5jdGlvbiBBbyh0KXtyZXR1cm4gZnVuY3Rp
b24oKXtyZXR1cm4gdH19ZnVuY3Rpb24gQ28odCl7cmV0dXJuIE1hdGguc3FydCh0LnZhbHVlKX1m
dW5jdGlvbiB6byh0KXtyZXR1cm4gZnVuY3Rpb24obil7bi5jaGlsZHJlbnx8KG4ucj1NYXRoLm1h
eCgwLCt0KG4pfHwwKSl9fWZ1bmN0aW9uIFBvKHQsbil7cmV0dXJuIGZ1bmN0aW9uKGUpe2lmKHI9
ZS5jaGlsZHJlbil7dmFyIHIsaSxvLHU9ci5sZW5ndGgsYT10KGUpKm58fDA7aWYoYSlmb3IoaT0w
O2k8dTsrK2kpcltpXS5yKz1hO2lmKG89a28ociksYSlmb3IoaT0wO2k8dTsrK2kpcltpXS5yLT1h
O2Uucj1vK2F9fX1mdW5jdGlvbiBSbyh0KXtyZXR1cm4gZnVuY3Rpb24obil7dmFyIGU9bi5wYXJl
bnQ7bi5yKj10LGUmJihuLng9ZS54K3Qqbi54LG4ueT1lLnkrdCpuLnkpfX1mdW5jdGlvbiBMbyh0
KXt0LngwPU1hdGgucm91bmQodC54MCksdC55MD1NYXRoLnJvdW5kKHQueTApLHQueDE9TWF0aC5y
b3VuZCh0LngxKSx0LnkxPU1hdGgucm91bmQodC55MSl9ZnVuY3Rpb24gcW8odCxuLGUscixpKXtm
b3IodmFyIG8sdT10LmNoaWxkcmVuLGE9LTEsYz11Lmxlbmd0aCxzPXQudmFsdWUmJihyLW4pL3Qu
dmFsdWU7KythPGM7KShvPXVbYV0pLnkwPWUsby55MT1pLG8ueDA9bixvLngxPW4rPW8udmFsdWUq
c31mdW5jdGlvbiBEbyh0KXtyZXR1cm4gdC5pZH1mdW5jdGlvbiBVbyh0KXtyZXR1cm4gdC5wYXJl
bnRJZH1mdW5jdGlvbiBPbyh0LG4pe3JldHVybiB0LnBhcmVudD09PW4ucGFyZW50PzE6Mn1mdW5j
dGlvbiBGbyh0KXt2YXIgbj10LmNoaWxkcmVuO3JldHVybiBuP25bMF06dC50fWZ1bmN0aW9uIElv
KHQpe3ZhciBuPXQuY2hpbGRyZW47cmV0dXJuIG4/bltuLmxlbmd0aC0xXTp0LnR9ZnVuY3Rpb24g
WW8odCxuLGUpe3ZhciByPWUvKG4uaS10LmkpO24uYy09cixuLnMrPWUsdC5jKz1yLG4ueis9ZSxu
Lm0rPWV9ZnVuY3Rpb24gQm8odCxuLGUpe3JldHVybiB0LmEucGFyZW50PT09bi5wYXJlbnQ/dC5h
OmV9ZnVuY3Rpb24gSG8odCxuKXt0aGlzLl89dCx0aGlzLnBhcmVudD1udWxsLHRoaXMuY2hpbGRy
ZW49bnVsbCx0aGlzLkE9bnVsbCx0aGlzLmE9dGhpcyx0aGlzLno9MCx0aGlzLm09MCx0aGlzLmM9
MCx0aGlzLnM9MCx0aGlzLnQ9bnVsbCx0aGlzLmk9bn1mdW5jdGlvbiBqbyh0LG4sZSxyLGkpe2Zv
cih2YXIgbyx1PXQuY2hpbGRyZW4sYT0tMSxjPXUubGVuZ3RoLHM9dC52YWx1ZSYmKGktZSkvdC52
YWx1ZTsrK2E8YzspKG89dVthXSkueDA9bixvLngxPXIsby55MD1lLG8ueTE9ZSs9by52YWx1ZSpz
fWZ1bmN0aW9uIFhvKHQsbixlLHIsaSxvKXtmb3IodmFyIHUsYSxjLHMsZixsLGgscCxkLHYsZyxf
PVtdLHk9bi5jaGlsZHJlbixtPTAseD0wLGI9eS5sZW5ndGgsdz1uLnZhbHVlO208Yjspe2M9aS1l
LHM9by1yO2Rve2Y9eVt4KytdLnZhbHVlfXdoaWxlKCFmJiZ4PGIpO2ZvcihsPWg9ZixnPWYqZioo
dj1NYXRoLm1heChzL2MsYy9zKS8odyp0KSksZD1NYXRoLm1heChoL2csZy9sKTt4PGI7Kyt4KXtp
ZihmKz1hPXlbeF0udmFsdWUsYTxsJiYobD1hKSxhPmgmJihoPWEpLGc9ZipmKnYsKHA9TWF0aC5t
YXgoaC9nLGcvbCkpPmQpe2YtPWE7YnJlYWt9ZD1wfV8ucHVzaCh1PXt2YWx1ZTpmLGRpY2U6Yzxz
LGNoaWxkcmVuOnkuc2xpY2UobSx4KX0pLHUuZGljZT9xbyh1LGUscixpLHc/cis9cypmL3c6byk6
am8odSxlLHIsdz9lKz1jKmYvdzppLG8pLHctPWYsbT14fXJldHVybiBffWZ1bmN0aW9uIFZvKHQs
bixlKXtyZXR1cm4oblswXS10WzBdKSooZVsxXS10WzFdKS0oblsxXS10WzFdKSooZVswXS10WzBd
KX1mdW5jdGlvbiAkbyh0LG4pe3JldHVybiB0WzBdLW5bMF18fHRbMV0tblsxXX1mdW5jdGlvbiBX
byh0KXtmb3IodmFyIG49dC5sZW5ndGgsZT1bMCwxXSxyPTIsaT0yO2k8bjsrK2kpe2Zvcig7cj4x
JiZWbyh0W2Vbci0yXV0sdFtlW3ItMV1dLHRbaV0pPD0wOyktLXI7ZVtyKytdPWl9cmV0dXJuIGUu
c2xpY2UoMCxyKX1mdW5jdGlvbiBabyh0KXt0aGlzLl9zaXplPXQsdGhpcy5fY2FsbD10aGlzLl9l
cnJvcj1udWxsLHRoaXMuX3Rhc2tzPVtdLHRoaXMuX2RhdGE9W10sdGhpcy5fd2FpdGluZz10aGlz
Ll9hY3RpdmU9dGhpcy5fZW5kZWQ9dGhpcy5fc3RhcnQ9MH1mdW5jdGlvbiBHbyh0KXtpZighdC5f
c3RhcnQpdHJ5eyhmdW5jdGlvbih0KXtmb3IoO3QuX3N0YXJ0PXQuX3dhaXRpbmcmJnQuX2FjdGl2
ZTx0Ll9zaXplOyl7dmFyIG49dC5fZW5kZWQrdC5fYWN0aXZlLGU9dC5fdGFza3Nbbl0scj1lLmxl
bmd0aC0xLGk9ZVtyXTtlW3JdPWZ1bmN0aW9uKHQsbil7cmV0dXJuIGZ1bmN0aW9uKGUscil7dC5f
dGFza3Nbbl0mJigtLXQuX2FjdGl2ZSwrK3QuX2VuZGVkLHQuX3Rhc2tzW25dPW51bGwsbnVsbD09
dC5fZXJyb3ImJihudWxsIT1lP1FvKHQsZSk6KHQuX2RhdGFbbl09cix0Ll93YWl0aW5nP0dvKHQp
OkpvKHQpKSkpfX0odCxuKSwtLXQuX3dhaXRpbmcsKyt0Ll9hY3RpdmUsZT1pLmFwcGx5KG51bGws
ZSksdC5fdGFza3Nbbl0mJih0Ll90YXNrc1tuXT1lfHxldil9fSkodCl9Y2F0Y2gobil7aWYodC5f
dGFza3NbdC5fZW5kZWQrdC5fYWN0aXZlLTFdKVFvKHQsbik7ZWxzZSBpZighdC5fZGF0YSl0aHJv
dyBufX1mdW5jdGlvbiBRbyh0LG4pe3ZhciBlLHI9dC5fdGFza3MubGVuZ3RoO2Zvcih0Ll9lcnJv
cj1uLHQuX2RhdGE9dm9pZCAwLHQuX3dhaXRpbmc9TmFOOy0tcj49MDspaWYoKGU9dC5fdGFza3Nb
cl0pJiYodC5fdGFza3Nbcl09bnVsbCxlLmFib3J0KSl0cnl7ZS5hYm9ydCgpfWNhdGNoKG4pe310
Ll9hY3RpdmU9TmFOLEpvKHQpfWZ1bmN0aW9uIEpvKHQpe2lmKCF0Ll9hY3RpdmUmJnQuX2NhbGwp
e3ZhciBuPXQuX2RhdGE7dC5fZGF0YT12b2lkIDAsdC5fY2FsbCh0Ll9lcnJvcixuKX19ZnVuY3Rp
b24gS28odCl7aWYobnVsbD09dCl0PTEvMDtlbHNlIGlmKCEoKHQ9K3QpPj0xKSl0aHJvdyBuZXcg
RXJyb3IoImludmFsaWQgY29uY3VycmVuY3kiKTtyZXR1cm4gbmV3IFpvKHQpfWZ1bmN0aW9uIHR1
KCl7cmV0dXJuIE1hdGgucmFuZG9tKCl9ZnVuY3Rpb24gbnUodCxuKXtmdW5jdGlvbiBlKHQpe3Zh
ciBuLGU9cy5zdGF0dXM7aWYoIWUmJmZ1bmN0aW9uKHQpe3ZhciBuPXQucmVzcG9uc2VUeXBlO3Jl
dHVybiBuJiYidGV4dCIhPT1uP3QucmVzcG9uc2U6dC5yZXNwb25zZVRleHR9KHMpfHxlPj0yMDAm
JmU8MzAwfHwzMDQ9PT1lKXtpZihvKXRyeXtuPW8uY2FsbChyLHMpfWNhdGNoKHQpe3JldHVybiB2
b2lkIGEuY2FsbCgiZXJyb3IiLHIsdCl9ZWxzZSBuPXM7YS5jYWxsKCJsb2FkIixyLG4pfWVsc2Ug
YS5jYWxsKCJlcnJvciIscix0KX12YXIgcixpLG8sdSxhPU4oImJlZm9yZXNlbmQiLCJwcm9ncmVz
cyIsImxvYWQiLCJlcnJvciIpLGM9c2UoKSxzPW5ldyBYTUxIdHRwUmVxdWVzdCxmPW51bGwsbD1u
dWxsLGg9MDtpZigidW5kZWZpbmVkIj09dHlwZW9mIFhEb21haW5SZXF1ZXN0fHwid2l0aENyZWRl
bnRpYWxzImluIHN8fCEvXihodHRwKHMpPzopP1wvXC8vLnRlc3QodCl8fChzPW5ldyBYRG9tYWlu
UmVxdWVzdCksIm9ubG9hZCJpbiBzP3Mub25sb2FkPXMub25lcnJvcj1zLm9udGltZW91dD1lOnMu
b25yZWFkeXN0YXRlY2hhbmdlPWZ1bmN0aW9uKHQpe3MucmVhZHlTdGF0ZT4zJiZlKHQpfSxzLm9u
cHJvZ3Jlc3M9ZnVuY3Rpb24odCl7YS5jYWxsKCJwcm9ncmVzcyIscix0KX0scj17aGVhZGVyOmZ1
bmN0aW9uKHQsbil7cmV0dXJuIHQ9KHQrIiIpLnRvTG93ZXJDYXNlKCksYXJndW1lbnRzLmxlbmd0
aDwyP2MuZ2V0KHQpOihudWxsPT1uP2MucmVtb3ZlKHQpOmMuc2V0KHQsbisiIikscil9LG1pbWVU
eXBlOmZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhpPW51bGw9PXQ/bnVsbDp0
KyIiLHIpOml9LHJlc3BvbnNlVHlwZTpmdW5jdGlvbih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0
aD8odT10LHIpOnV9LHRpbWVvdXQ6ZnVuY3Rpb24odCl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/
KGg9K3Qscik6aH0sdXNlcjpmdW5jdGlvbih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aDwxP2Y6
KGY9bnVsbD09dD9udWxsOnQrIiIscil9LHBhc3N3b3JkOmZ1bmN0aW9uKHQpe3JldHVybiBhcmd1
bWVudHMubGVuZ3RoPDE/bDoobD1udWxsPT10P251bGw6dCsiIixyKX0scmVzcG9uc2U6ZnVuY3Rp
b24odCl7cmV0dXJuIG89dCxyfSxnZXQ6ZnVuY3Rpb24odCxuKXtyZXR1cm4gci5zZW5kKCJHRVQi
LHQsbil9LHBvc3Q6ZnVuY3Rpb24odCxuKXtyZXR1cm4gci5zZW5kKCJQT1NUIix0LG4pfSxzZW5k
OmZ1bmN0aW9uKG4sZSxvKXtyZXR1cm4gcy5vcGVuKG4sdCwhMCxmLGwpLG51bGw9PWl8fGMuaGFz
KCJhY2NlcHQiKXx8Yy5zZXQoImFjY2VwdCIsaSsiLCovKiIpLHMuc2V0UmVxdWVzdEhlYWRlciYm
Yy5lYWNoKGZ1bmN0aW9uKHQsbil7cy5zZXRSZXF1ZXN0SGVhZGVyKG4sdCl9KSxudWxsIT1pJiZz
Lm92ZXJyaWRlTWltZVR5cGUmJnMub3ZlcnJpZGVNaW1lVHlwZShpKSxudWxsIT11JiYocy5yZXNw
b25zZVR5cGU9dSksaD4wJiYocy50aW1lb3V0PWgpLG51bGw9PW8mJiJmdW5jdGlvbiI9PXR5cGVv
ZiBlJiYobz1lLGU9bnVsbCksbnVsbCE9byYmMT09PW8ubGVuZ3RoJiYobz1mdW5jdGlvbih0KXty
ZXR1cm4gZnVuY3Rpb24obixlKXt0KG51bGw9PW4/ZTpudWxsKX19KG8pKSxudWxsIT1vJiZyLm9u
KCJlcnJvciIsbykub24oImxvYWQiLGZ1bmN0aW9uKHQpe28obnVsbCx0KX0pLGEuY2FsbCgiYmVm
b3Jlc2VuZCIscixzKSxzLnNlbmQobnVsbD09ZT9udWxsOmUpLHJ9LGFib3J0OmZ1bmN0aW9uKCl7
cmV0dXJuIHMuYWJvcnQoKSxyfSxvbjpmdW5jdGlvbigpe3ZhciB0PWEub24uYXBwbHkoYSxhcmd1
bWVudHMpO3JldHVybiB0PT09YT9yOnR9fSxudWxsIT1uKXtpZigiZnVuY3Rpb24iIT10eXBlb2Yg
bil0aHJvdyBuZXcgRXJyb3IoImludmFsaWQgY2FsbGJhY2s6ICIrbik7cmV0dXJuIHIuZ2V0KG4p
fXJldHVybiByfWZ1bmN0aW9uIGV1KHQsbil7cmV0dXJuIGZ1bmN0aW9uKGUscil7dmFyIGk9bnUo
ZSkubWltZVR5cGUodCkucmVzcG9uc2Uobik7aWYobnVsbCE9cil7aWYoImZ1bmN0aW9uIiE9dHlw
ZW9mIHIpdGhyb3cgbmV3IEVycm9yKCJpbnZhbGlkIGNhbGxiYWNrOiAiK3IpO3JldHVybiBpLmdl
dChyKX1yZXR1cm4gaX19ZnVuY3Rpb24gcnUodCxuKXtyZXR1cm4gZnVuY3Rpb24oZSxyLGkpe2Fy
Z3VtZW50cy5sZW5ndGg8MyYmKGk9cixyPW51bGwpO3ZhciBvPW51KGUpLm1pbWVUeXBlKHQpO3Jl
dHVybiBvLnJvdz1mdW5jdGlvbih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD9vLnJlc3BvbnNl
KGZ1bmN0aW9uKHQsbil7cmV0dXJuIGZ1bmN0aW9uKGUpe3JldHVybiB0KGUucmVzcG9uc2VUZXh0
LG4pfX0obixyPXQpKTpyfSxvLnJvdyhyKSxpP28uZ2V0KGkpOm99fWZ1bmN0aW9uIGl1KHQpe2Z1
bmN0aW9uIG4obil7dmFyIG89bisiIix1PWUuZ2V0KG8pO2lmKCF1KXtpZihpIT09eXYpcmV0dXJu
IGk7ZS5zZXQobyx1PXIucHVzaChuKSl9cmV0dXJuIHRbKHUtMSkldC5sZW5ndGhdfXZhciBlPXNl
KCkscj1bXSxpPXl2O3JldHVybiB0PW51bGw9PXQ/W106X3YuY2FsbCh0KSxuLmRvbWFpbj1mdW5j
dGlvbih0KXtpZighYXJndW1lbnRzLmxlbmd0aClyZXR1cm4gci5zbGljZSgpO3I9W10sZT1zZSgp
O2Zvcih2YXIgaSxvLHU9LTEsYT10Lmxlbmd0aDsrK3U8YTspZS5oYXMobz0oaT10W3VdKSsiIil8
fGUuc2V0KG8sci5wdXNoKGkpKTtyZXR1cm4gbn0sbi5yYW5nZT1mdW5jdGlvbihlKXtyZXR1cm4g
YXJndW1lbnRzLmxlbmd0aD8odD1fdi5jYWxsKGUpLG4pOnQuc2xpY2UoKX0sbi51bmtub3duPWZ1
bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhpPXQsbik6aX0sbi5jb3B5PWZ1bmN0
aW9uKCl7cmV0dXJuIGl1KCkuZG9tYWluKHIpLnJhbmdlKHQpLnVua25vd24oaSl9LG59ZnVuY3Rp
b24gb3UoKXtmdW5jdGlvbiB0KCl7dmFyIHQ9aSgpLmxlbmd0aCxyPXVbMV08dVswXSxoPXVbci0w
XSxwPXVbMS1yXTtuPShwLWgpL01hdGgubWF4KDEsdC1jKzIqcyksYSYmKG49TWF0aC5mbG9vcihu
KSksaCs9KHAtaC1uKih0LWMpKSpsLGU9biooMS1jKSxhJiYoaD1NYXRoLnJvdW5kKGgpLGU9TWF0
aC5yb3VuZChlKSk7dmFyIGQ9Zih0KS5tYXAoZnVuY3Rpb24odCl7cmV0dXJuIGgrbip0fSk7cmV0
dXJuIG8ocj9kLnJldmVyc2UoKTpkKX12YXIgbixlLHI9aXUoKS51bmtub3duKHZvaWQgMCksaT1y
LmRvbWFpbixvPXIucmFuZ2UsdT1bMCwxXSxhPSExLGM9MCxzPTAsbD0uNTtyZXR1cm4gZGVsZXRl
IHIudW5rbm93bixyLmRvbWFpbj1mdW5jdGlvbihuKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8o
aShuKSx0KCkpOmkoKX0sci5yYW5nZT1mdW5jdGlvbihuKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0
aD8odT1bK25bMF0sK25bMV1dLHQoKSk6dS5zbGljZSgpfSxyLnJhbmdlUm91bmQ9ZnVuY3Rpb24o
bil7cmV0dXJuIHU9WytuWzBdLCtuWzFdXSxhPSEwLHQoKX0sci5iYW5kd2lkdGg9ZnVuY3Rpb24o
KXtyZXR1cm4gZX0sci5zdGVwPWZ1bmN0aW9uKCl7cmV0dXJuIG59LHIucm91bmQ9ZnVuY3Rpb24o
bil7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KGE9ISFuLHQoKSk6YX0sci5wYWRkaW5nPWZ1bmN0
aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhjPXM9TWF0aC5tYXgoMCxNYXRoLm1pbigx
LG4pKSx0KCkpOmN9LHIucGFkZGluZ0lubmVyPWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMu
bGVuZ3RoPyhjPU1hdGgubWF4KDAsTWF0aC5taW4oMSxuKSksdCgpKTpjfSxyLnBhZGRpbmdPdXRl
cj1mdW5jdGlvbihuKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8ocz1NYXRoLm1heCgwLE1hdGgu
bWluKDEsbikpLHQoKSk6c30sci5hbGlnbj1mdW5jdGlvbihuKXtyZXR1cm4gYXJndW1lbnRzLmxl
bmd0aD8obD1NYXRoLm1heCgwLE1hdGgubWluKDEsbikpLHQoKSk6bH0sci5jb3B5PWZ1bmN0aW9u
KCl7cmV0dXJuIG91KCkuZG9tYWluKGkoKSkucmFuZ2UodSkucm91bmQoYSkucGFkZGluZ0lubmVy
KGMpLnBhZGRpbmdPdXRlcihzKS5hbGlnbihsKX0sdCgpfWZ1bmN0aW9uIHV1KHQpe3ZhciBuPXQu
Y29weTtyZXR1cm4gdC5wYWRkaW5nPXQucGFkZGluZ091dGVyLGRlbGV0ZSB0LnBhZGRpbmdJbm5l
cixkZWxldGUgdC5wYWRkaW5nT3V0ZXIsdC5jb3B5PWZ1bmN0aW9uKCl7cmV0dXJuIHV1KG4oKSl9
LHR9ZnVuY3Rpb24gYXUodCl7cmV0dXJuIGZ1bmN0aW9uKCl7cmV0dXJuIHR9fWZ1bmN0aW9uIGN1
KHQpe3JldHVybit0fWZ1bmN0aW9uIHN1KHQsbil7cmV0dXJuKG4tPXQ9K3QpP2Z1bmN0aW9uKGUp
e3JldHVybihlLXQpL259OmF1KG4pfWZ1bmN0aW9uIGZ1KHQsbixlLHIpe3ZhciBpPXRbMF0sbz10
WzFdLHU9blswXSxhPW5bMV07cmV0dXJuIG88aT8oaT1lKG8saSksdT1yKGEsdSkpOihpPWUoaSxv
KSx1PXIodSxhKSksZnVuY3Rpb24odCl7cmV0dXJuIHUoaSh0KSl9fWZ1bmN0aW9uIGx1KHQsbixl
LHIpe3ZhciBpPU1hdGgubWluKHQubGVuZ3RoLG4ubGVuZ3RoKS0xLG89bmV3IEFycmF5KGkpLHU9
bmV3IEFycmF5KGkpLGE9LTE7Zm9yKHRbaV08dFswXSYmKHQ9dC5zbGljZSgpLnJldmVyc2UoKSxu
PW4uc2xpY2UoKS5yZXZlcnNlKCkpOysrYTxpOylvW2FdPWUodFthXSx0W2ErMV0pLHVbYV09cihu
W2FdLG5bYSsxXSk7cmV0dXJuIGZ1bmN0aW9uKG4pe3ZhciBlPU9zKHQsbiwxLGkpLTE7cmV0dXJu
IHVbZV0ob1tlXShuKSl9fWZ1bmN0aW9uIGh1KHQsbil7cmV0dXJuIG4uZG9tYWluKHQuZG9tYWlu
KCkpLnJhbmdlKHQucmFuZ2UoKSkuaW50ZXJwb2xhdGUodC5pbnRlcnBvbGF0ZSgpKS5jbGFtcCh0
LmNsYW1wKCkpfWZ1bmN0aW9uIHB1KHQsbil7ZnVuY3Rpb24gZSgpe3JldHVybiBpPU1hdGgubWlu
KGEubGVuZ3RoLGMubGVuZ3RoKT4yP2x1OmZ1LG89dT1udWxsLHJ9ZnVuY3Rpb24gcihuKXtyZXR1
cm4ob3x8KG89aShhLGMsZj9mdW5jdGlvbih0KXtyZXR1cm4gZnVuY3Rpb24obixlKXt2YXIgcj10
KG49K24sZT0rZSk7cmV0dXJuIGZ1bmN0aW9uKHQpe3JldHVybiB0PD1uPzA6dD49ZT8xOnIodCl9
fX0odCk6dCxzKSkpKCtuKX12YXIgaSxvLHUsYT1tdixjPW12LHM9Zm4sZj0hMTtyZXR1cm4gci5p
bnZlcnQ9ZnVuY3Rpb24odCl7cmV0dXJuKHV8fCh1PWkoYyxhLHN1LGY/ZnVuY3Rpb24odCl7cmV0
dXJuIGZ1bmN0aW9uKG4sZSl7dmFyIHI9dChuPStuLGU9K2UpO3JldHVybiBmdW5jdGlvbih0KXty
ZXR1cm4gdDw9MD9uOnQ+PTE/ZTpyKHQpfX19KG4pOm4pKSkoK3QpfSxyLmRvbWFpbj1mdW5jdGlv
bih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oYT1ndi5jYWxsKHQsY3UpLGUoKSk6YS5zbGlj
ZSgpfSxyLnJhbmdlPWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhjPV92LmNh
bGwodCksZSgpKTpjLnNsaWNlKCl9LHIucmFuZ2VSb3VuZD1mdW5jdGlvbih0KXtyZXR1cm4gYz1f
di5jYWxsKHQpLHM9bG4sZSgpfSxyLmNsYW1wPWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMu
bGVuZ3RoPyhmPSEhdCxlKCkpOmZ9LHIuaW50ZXJwb2xhdGU9ZnVuY3Rpb24odCl7cmV0dXJuIGFy
Z3VtZW50cy5sZW5ndGg/KHM9dCxlKCkpOnN9LGUoKX1mdW5jdGlvbiBkdShuKXt2YXIgZT1uLmRv
bWFpbjtyZXR1cm4gbi50aWNrcz1mdW5jdGlvbih0KXt2YXIgbj1lKCk7cmV0dXJuIGwoblswXSxu
W24ubGVuZ3RoLTFdLG51bGw9PXQ/MTA6dCl9LG4udGlja0Zvcm1hdD1mdW5jdGlvbihuLHIpe3Jl
dHVybiBmdW5jdGlvbihuLGUscil7dmFyIGksbz1uWzBdLHU9bltuLmxlbmd0aC0xXSxhPXAobyx1
LG51bGw9PWU/MTA6ZSk7c3dpdGNoKChyPURlKG51bGw9PXI/IixmIjpyKSkudHlwZSl7Y2FzZSJz
Ijp2YXIgYz1NYXRoLm1heChNYXRoLmFicyhvKSxNYXRoLmFicyh1KSk7cmV0dXJuIG51bGwhPXIu
cHJlY2lzaW9ufHxpc05hTihpPUJlKGEsYykpfHwoci5wcmVjaXNpb249aSksdC5mb3JtYXRQcmVm
aXgocixjKTtjYXNlIiI6Y2FzZSJlIjpjYXNlImciOmNhc2UicCI6Y2FzZSJyIjpudWxsIT1yLnBy
ZWNpc2lvbnx8aXNOYU4oaT1IZShhLE1hdGgubWF4KE1hdGguYWJzKG8pLE1hdGguYWJzKHUpKSkp
fHwoci5wcmVjaXNpb249aS0oImUiPT09ci50eXBlKSk7YnJlYWs7Y2FzZSJmIjpjYXNlIiUiOm51
bGwhPXIucHJlY2lzaW9ufHxpc05hTihpPVllKGEpKXx8KHIucHJlY2lzaW9uPWktMiooIiUiPT09
ci50eXBlKSl9cmV0dXJuIHQuZm9ybWF0KHIpfShlKCksbixyKX0sbi5uaWNlPWZ1bmN0aW9uKHQp
e251bGw9PXQmJih0PTEwKTt2YXIgcixpPWUoKSxvPTAsdT1pLmxlbmd0aC0xLGE9aVtvXSxjPWlb
dV07cmV0dXJuIGM8YSYmKHI9YSxhPWMsYz1yLHI9byxvPXUsdT1yKSwocj1oKGEsYyx0KSk+MD9y
PWgoYT1NYXRoLmZsb29yKGEvcikqcixjPU1hdGguY2VpbChjL3IpKnIsdCk6cjwwJiYocj1oKGE9
TWF0aC5jZWlsKGEqcikvcixjPU1hdGguZmxvb3IoYypyKS9yLHQpKSxyPjA/KGlbb109TWF0aC5m
bG9vcihhL3IpKnIsaVt1XT1NYXRoLmNlaWwoYy9yKSpyLGUoaSkpOnI8MCYmKGlbb109TWF0aC5j
ZWlsKGEqcikvcixpW3VdPU1hdGguZmxvb3IoYypyKS9yLGUoaSkpLG59LG59ZnVuY3Rpb24gdnUo
KXt2YXIgdD1wdShzdSxhbik7cmV0dXJuIHQuY29weT1mdW5jdGlvbigpe3JldHVybiBodSh0LHZ1
KCkpfSxkdSh0KX1mdW5jdGlvbiBndSgpe2Z1bmN0aW9uIHQodCl7cmV0dXJuK3R9dmFyIG49WzAs
MV07cmV0dXJuIHQuaW52ZXJ0PXQsdC5kb21haW49dC5yYW5nZT1mdW5jdGlvbihlKXtyZXR1cm4g
YXJndW1lbnRzLmxlbmd0aD8obj1ndi5jYWxsKGUsY3UpLHQpOm4uc2xpY2UoKX0sdC5jb3B5PWZ1
bmN0aW9uKCl7cmV0dXJuIGd1KCkuZG9tYWluKG4pfSxkdSh0KX1mdW5jdGlvbiBfdSh0LG4pe3Zh
ciBlLHI9MCxpPSh0PXQuc2xpY2UoKSkubGVuZ3RoLTEsbz10W3JdLHU9dFtpXTtyZXR1cm4gdTxv
JiYoZT1yLHI9aSxpPWUsZT1vLG89dSx1PWUpLHRbcl09bi5mbG9vcihvKSx0W2ldPW4uY2VpbCh1
KSx0fWZ1bmN0aW9uIHl1KHQsbil7cmV0dXJuKG49TWF0aC5sb2cobi90KSk/ZnVuY3Rpb24oZSl7
cmV0dXJuIE1hdGgubG9nKGUvdCkvbn06YXUobil9ZnVuY3Rpb24gbXUodCxuKXtyZXR1cm4gdDww
P2Z1bmN0aW9uKGUpe3JldHVybi1NYXRoLnBvdygtbixlKSpNYXRoLnBvdygtdCwxLWUpfTpmdW5j
dGlvbihlKXtyZXR1cm4gTWF0aC5wb3cobixlKSpNYXRoLnBvdyh0LDEtZSl9fWZ1bmN0aW9uIHh1
KHQpe3JldHVybiBpc0Zpbml0ZSh0KT8rKCIxZSIrdCk6dDwwPzA6dH1mdW5jdGlvbiBidSh0KXty
ZXR1cm4gMTA9PT10P3h1OnQ9PT1NYXRoLkU/TWF0aC5leHA6ZnVuY3Rpb24obil7cmV0dXJuIE1h
dGgucG93KHQsbil9fWZ1bmN0aW9uIHd1KHQpe3JldHVybiB0PT09TWF0aC5FP01hdGgubG9nOjEw
PT09dCYmTWF0aC5sb2cxMHx8Mj09PXQmJk1hdGgubG9nMnx8KHQ9TWF0aC5sb2codCksZnVuY3Rp
b24obil7cmV0dXJuIE1hdGgubG9nKG4pL3R9KX1mdW5jdGlvbiBNdSh0KXtyZXR1cm4gZnVuY3Rp
b24obil7cmV0dXJuLXQoLW4pfX1mdW5jdGlvbiBUdSgpe2Z1bmN0aW9uIG4oKXtyZXR1cm4gbz13
dShpKSx1PWJ1KGkpLHIoKVswXTwwJiYobz1NdShvKSx1PU11KHUpKSxlfXZhciBlPXB1KHl1LG11
KS5kb21haW4oWzEsMTBdKSxyPWUuZG9tYWluLGk9MTAsbz13dSgxMCksdT1idSgxMCk7cmV0dXJu
IGUuYmFzZT1mdW5jdGlvbih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oaT0rdCxuKCkpOml9
LGUuZG9tYWluPWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhyKHQpLG4oKSk6
cigpfSxlLnRpY2tzPWZ1bmN0aW9uKHQpe3ZhciBuLGU9cigpLGE9ZVswXSxjPWVbZS5sZW5ndGgt
MV07KG49YzxhKSYmKHA9YSxhPWMsYz1wKTt2YXIgcyxmLGgscD1vKGEpLGQ9byhjKSx2PW51bGw9
PXQ/MTA6K3QsZz1bXTtpZighKGklMSkmJmQtcDx2KXtpZihwPU1hdGgucm91bmQocCktMSxkPU1h
dGgucm91bmQoZCkrMSxhPjApe2Zvcig7cDxkOysrcClmb3IoZj0xLHM9dShwKTtmPGk7KytmKWlm
KCEoKGg9cypmKTxhKSl7aWYoaD5jKWJyZWFrO2cucHVzaChoKX19ZWxzZSBmb3IoO3A8ZDsrK3Ap
Zm9yKGY9aS0xLHM9dShwKTtmPj0xOy0tZilpZighKChoPXMqZik8YSkpe2lmKGg+YylicmVhaztn
LnB1c2goaCl9fWVsc2UgZz1sKHAsZCxNYXRoLm1pbihkLXAsdikpLm1hcCh1KTtyZXR1cm4gbj9n
LnJldmVyc2UoKTpnfSxlLnRpY2tGb3JtYXQ9ZnVuY3Rpb24obixyKXtpZihudWxsPT1yJiYocj0x
MD09PWk/Ii4wZSI6IiwiKSwiZnVuY3Rpb24iIT10eXBlb2YgciYmKHI9dC5mb3JtYXQocikpLG49
PT0xLzApcmV0dXJuIHI7bnVsbD09biYmKG49MTApO3ZhciBhPU1hdGgubWF4KDEsaSpuL2UudGlj
a3MoKS5sZW5ndGgpO3JldHVybiBmdW5jdGlvbih0KXt2YXIgbj10L3UoTWF0aC5yb3VuZChvKHQp
KSk7cmV0dXJuIG4qaTxpLS41JiYobio9aSksbjw9YT9yKHQpOiIifX0sZS5uaWNlPWZ1bmN0aW9u
KCl7cmV0dXJuIHIoX3UocigpLHtmbG9vcjpmdW5jdGlvbih0KXtyZXR1cm4gdShNYXRoLmZsb29y
KG8odCkpKX0sY2VpbDpmdW5jdGlvbih0KXtyZXR1cm4gdShNYXRoLmNlaWwobyh0KSkpfX0pKX0s
ZS5jb3B5PWZ1bmN0aW9uKCl7cmV0dXJuIGh1KGUsVHUoKS5iYXNlKGkpKX0sZX1mdW5jdGlvbiBO
dSh0LG4pe3JldHVybiB0PDA/LU1hdGgucG93KC10LG4pOk1hdGgucG93KHQsbil9ZnVuY3Rpb24g
a3UoKXt2YXIgdD0xLG49cHUoZnVuY3Rpb24obixlKXtyZXR1cm4oZT1OdShlLHQpLShuPU51KG4s
dCkpKT9mdW5jdGlvbihyKXtyZXR1cm4oTnUocix0KS1uKS9lfTphdShlKX0sZnVuY3Rpb24obixl
KXtyZXR1cm4gZT1OdShlLHQpLShuPU51KG4sdCkpLGZ1bmN0aW9uKHIpe3JldHVybiBOdShuK2Uq
ciwxL3QpfX0pLGU9bi5kb21haW47cmV0dXJuIG4uZXhwb25lbnQ9ZnVuY3Rpb24obil7cmV0dXJu
IGFyZ3VtZW50cy5sZW5ndGg/KHQ9K24sZShlKCkpKTp0fSxuLmNvcHk9ZnVuY3Rpb24oKXtyZXR1
cm4gaHUobixrdSgpLmV4cG9uZW50KHQpKX0sZHUobil9ZnVuY3Rpb24gU3UoKXtmdW5jdGlvbiB0
KCl7dmFyIHQ9MCxuPU1hdGgubWF4KDEsaS5sZW5ndGgpO2ZvcihvPW5ldyBBcnJheShuLTEpOysr
dDxuOylvW3QtMV09dihyLHQvbik7cmV0dXJuIGV9ZnVuY3Rpb24gZSh0KXtpZighaXNOYU4odD0r
dCkpcmV0dXJuIGlbT3Mobyx0KV19dmFyIHI9W10saT1bXSxvPVtdO3JldHVybiBlLmludmVydEV4
dGVudD1mdW5jdGlvbih0KXt2YXIgbj1pLmluZGV4T2YodCk7cmV0dXJuIG48MD9bTmFOLE5hTl06
W24+MD9vW24tMV06clswXSxuPG8ubGVuZ3RoP29bbl06cltyLmxlbmd0aC0xXV19LGUuZG9tYWlu
PWZ1bmN0aW9uKGUpe2lmKCFhcmd1bWVudHMubGVuZ3RoKXJldHVybiByLnNsaWNlKCk7cj1bXTtm
b3IodmFyIGksbz0wLHU9ZS5sZW5ndGg7bzx1OysrbyludWxsPT0oaT1lW29dKXx8aXNOYU4oaT0r
aSl8fHIucHVzaChpKTtyZXR1cm4gci5zb3J0KG4pLHQoKX0sZS5yYW5nZT1mdW5jdGlvbihuKXty
ZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oaT1fdi5jYWxsKG4pLHQoKSk6aS5zbGljZSgpfSxlLnF1
YW50aWxlcz1mdW5jdGlvbigpe3JldHVybiBvLnNsaWNlKCl9LGUuY29weT1mdW5jdGlvbigpe3Jl
dHVybiBTdSgpLmRvbWFpbihyKS5yYW5nZShpKX0sZX1mdW5jdGlvbiBFdSgpe2Z1bmN0aW9uIHQo
dCl7aWYodDw9dClyZXR1cm4gdVtPcyhvLHQsMCxpKV19ZnVuY3Rpb24gbigpe3ZhciBuPS0xO2Zv
cihvPW5ldyBBcnJheShpKTsrK248aTspb1tuXT0oKG4rMSkqci0obi1pKSplKS8oaSsxKTtyZXR1
cm4gdH12YXIgZT0wLHI9MSxpPTEsbz1bLjVdLHU9WzAsMV07cmV0dXJuIHQuZG9tYWluPWZ1bmN0
aW9uKHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhlPSt0WzBdLHI9K3RbMV0sbigpKTpbZSxy
XX0sdC5yYW5nZT1mdW5jdGlvbih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oaT0odT1fdi5j
YWxsKHQpKS5sZW5ndGgtMSxuKCkpOnUuc2xpY2UoKX0sdC5pbnZlcnRFeHRlbnQ9ZnVuY3Rpb24o
dCl7dmFyIG49dS5pbmRleE9mKHQpO3JldHVybiBuPDA/W05hTixOYU5dOm48MT9bZSxvWzBdXTpu
Pj1pP1tvW2ktMV0scl06W29bbi0xXSxvW25dXX0sdC5jb3B5PWZ1bmN0aW9uKCl7cmV0dXJuIEV1
KCkuZG9tYWluKFtlLHJdKS5yYW5nZSh1KX0sZHUodCl9ZnVuY3Rpb24gQXUoKXtmdW5jdGlvbiB0
KHQpe2lmKHQ8PXQpcmV0dXJuIGVbT3Mobix0LDAscildfXZhciBuPVsuNV0sZT1bMCwxXSxyPTE7
cmV0dXJuIHQuZG9tYWluPWZ1bmN0aW9uKGkpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhuPV92
LmNhbGwoaSkscj1NYXRoLm1pbihuLmxlbmd0aCxlLmxlbmd0aC0xKSx0KTpuLnNsaWNlKCl9LHQu
cmFuZ2U9ZnVuY3Rpb24oaSl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KGU9X3YuY2FsbChpKSxy
PU1hdGgubWluKG4ubGVuZ3RoLGUubGVuZ3RoLTEpLHQpOmUuc2xpY2UoKX0sdC5pbnZlcnRFeHRl
bnQ9ZnVuY3Rpb24odCl7dmFyIHI9ZS5pbmRleE9mKHQpO3JldHVybltuW3ItMV0sbltyXV19LHQu
Y29weT1mdW5jdGlvbigpe3JldHVybiBBdSgpLmRvbWFpbihuKS5yYW5nZShlKX0sdH1mdW5jdGlv
biBDdSh0LG4sZSxyKXtmdW5jdGlvbiBpKG4pe3JldHVybiB0KG49bmV3IERhdGUoK24pKSxufXJl
dHVybiBpLmZsb29yPWksaS5jZWlsPWZ1bmN0aW9uKGUpe3JldHVybiB0KGU9bmV3IERhdGUoZS0x
KSksbihlLDEpLHQoZSksZX0saS5yb3VuZD1mdW5jdGlvbih0KXt2YXIgbj1pKHQpLGU9aS5jZWls
KHQpO3JldHVybiB0LW48ZS10P246ZX0saS5vZmZzZXQ9ZnVuY3Rpb24odCxlKXtyZXR1cm4gbih0
PW5ldyBEYXRlKCt0KSxudWxsPT1lPzE6TWF0aC5mbG9vcihlKSksdH0saS5yYW5nZT1mdW5jdGlv
bihlLHIsbyl7dmFyIHUsYT1bXTtpZihlPWkuY2VpbChlKSxvPW51bGw9PW8/MTpNYXRoLmZsb29y
KG8pLCEoZTxyJiZvPjApKXJldHVybiBhO2Rve2EucHVzaCh1PW5ldyBEYXRlKCtlKSksbihlLG8p
LHQoZSl9d2hpbGUodTxlJiZlPHIpO3JldHVybiBhfSxpLmZpbHRlcj1mdW5jdGlvbihlKXtyZXR1
cm4gQ3UoZnVuY3Rpb24obil7aWYobj49bilmb3IoO3QobiksIWUobik7KW4uc2V0VGltZShuLTEp
fSxmdW5jdGlvbih0LHIpe2lmKHQ+PXQpaWYocjwwKWZvcig7KytyPD0wOylmb3IoO24odCwtMSks
IWUodCk7KTtlbHNlIGZvcig7LS1yPj0wOylmb3IoO24odCwxKSwhZSh0KTspO30pfSxlJiYoaS5j
b3VudD1mdW5jdGlvbihuLHIpe3JldHVybiB4di5zZXRUaW1lKCtuKSxidi5zZXRUaW1lKCtyKSx0
KHh2KSx0KGJ2KSxNYXRoLmZsb29yKGUoeHYsYnYpKX0saS5ldmVyeT1mdW5jdGlvbih0KXtyZXR1
cm4gdD1NYXRoLmZsb29yKHQpLGlzRmluaXRlKHQpJiZ0PjA/dD4xP2kuZmlsdGVyKHI/ZnVuY3Rp
b24obil7cmV0dXJuIHIobikldD09MH06ZnVuY3Rpb24obil7cmV0dXJuIGkuY291bnQoMCxuKSV0
PT0wfSk6aTpudWxsfSksaX1mdW5jdGlvbiB6dSh0KXtyZXR1cm4gQ3UoZnVuY3Rpb24obil7bi5z
ZXREYXRlKG4uZ2V0RGF0ZSgpLShuLmdldERheSgpKzctdCklNyksbi5zZXRIb3VycygwLDAsMCww
KX0sZnVuY3Rpb24odCxuKXt0LnNldERhdGUodC5nZXREYXRlKCkrNypuKX0sZnVuY3Rpb24odCxu
KXtyZXR1cm4obi10LShuLmdldFRpbWV6b25lT2Zmc2V0KCktdC5nZXRUaW1lem9uZU9mZnNldCgp
KSpUdikvTnZ9KX1mdW5jdGlvbiBQdSh0KXtyZXR1cm4gQ3UoZnVuY3Rpb24obil7bi5zZXRVVENE
YXRlKG4uZ2V0VVRDRGF0ZSgpLShuLmdldFVUQ0RheSgpKzctdCklNyksbi5zZXRVVENIb3Vycygw
LDAsMCwwKX0sZnVuY3Rpb24odCxuKXt0LnNldFVUQ0RhdGUodC5nZXRVVENEYXRlKCkrNypuKX0s
ZnVuY3Rpb24odCxuKXtyZXR1cm4obi10KS9Odn0pfWZ1bmN0aW9uIFJ1KHQpe2lmKDA8PXQueSYm
dC55PDEwMCl7dmFyIG49bmV3IERhdGUoLTEsdC5tLHQuZCx0LkgsdC5NLHQuUyx0LkwpO3JldHVy
biBuLnNldEZ1bGxZZWFyKHQueSksbn1yZXR1cm4gbmV3IERhdGUodC55LHQubSx0LmQsdC5ILHQu
TSx0LlMsdC5MKX1mdW5jdGlvbiBMdSh0KXtpZigwPD10LnkmJnQueTwxMDApe3ZhciBuPW5ldyBE
YXRlKERhdGUuVVRDKC0xLHQubSx0LmQsdC5ILHQuTSx0LlMsdC5MKSk7cmV0dXJuIG4uc2V0VVRD
RnVsbFllYXIodC55KSxufXJldHVybiBuZXcgRGF0ZShEYXRlLlVUQyh0LnksdC5tLHQuZCx0Lkgs
dC5NLHQuUyx0LkwpKX1mdW5jdGlvbiBxdSh0KXtyZXR1cm57eTp0LG06MCxkOjEsSDowLE06MCxT
OjAsTDowfX1mdW5jdGlvbiBEdSh0KXtmdW5jdGlvbiBuKHQsbil7cmV0dXJuIGZ1bmN0aW9uKGUp
e3ZhciByLGksbyx1PVtdLGE9LTEsYz0wLHM9dC5sZW5ndGg7Zm9yKGUgaW5zdGFuY2VvZiBEYXRl
fHwoZT1uZXcgRGF0ZSgrZSkpOysrYTxzOykzNz09PXQuY2hhckNvZGVBdChhKSYmKHUucHVzaCh0
LnNsaWNlKGMsYSkpLG51bGwhPShpPU1nW3I9dC5jaGFyQXQoKythKV0pP3I9dC5jaGFyQXQoKyth
KTppPSJlIj09PXI/IiAiOiIwIiwobz1uW3JdKSYmKHI9byhlLGkpKSx1LnB1c2gociksYz1hKzEp
O3JldHVybiB1LnB1c2godC5zbGljZShjLGEpKSx1LmpvaW4oIiIpfX1mdW5jdGlvbiBlKHQsbil7
cmV0dXJuIGZ1bmN0aW9uKGUpe3ZhciBpLG8sdT1xdSgxOTAwKTtpZihyKHUsdCxlKz0iIiwwKSE9
ZS5sZW5ndGgpcmV0dXJuIG51bGw7aWYoIlEiaW4gdSlyZXR1cm4gbmV3IERhdGUodS5RKTtpZigi
cCJpbiB1JiYodS5IPXUuSCUxMisxMip1LnApLCJWImluIHUpe2lmKHUuVjwxfHx1LlY+NTMpcmV0
dXJuIG51bGw7InciaW4gdXx8KHUudz0xKSwiWiJpbiB1PyhpPShvPShpPUx1KHF1KHUueSkpKS5n
ZXRVVENEYXkoKSk+NHx8MD09PW8/b2cuY2VpbChpKTpvZyhpKSxpPWVnLm9mZnNldChpLDcqKHUu
Vi0xKSksdS55PWkuZ2V0VVRDRnVsbFllYXIoKSx1Lm09aS5nZXRVVENNb250aCgpLHUuZD1pLmdl
dFVUQ0RhdGUoKSsodS53KzYpJTcpOihpPShvPShpPW4ocXUodS55KSkpLmdldERheSgpKT40fHww
PT09bz9xdi5jZWlsKGkpOnF2KGkpLGk9UHYub2Zmc2V0KGksNyoodS5WLTEpKSx1Lnk9aS5nZXRG
dWxsWWVhcigpLHUubT1pLmdldE1vbnRoKCksdS5kPWkuZ2V0RGF0ZSgpKyh1LncrNiklNyl9ZWxz
ZSgiVyJpbiB1fHwiVSJpbiB1KSYmKCJ3ImluIHV8fCh1Lnc9InUiaW4gdT91LnUlNzoiVyJpbiB1
PzE6MCksbz0iWiJpbiB1P0x1KHF1KHUueSkpLmdldFVUQ0RheSgpOm4ocXUodS55KSkuZ2V0RGF5
KCksdS5tPTAsdS5kPSJXImluIHU/KHUudys2KSU3KzcqdS5XLShvKzUpJTc6dS53KzcqdS5VLShv
KzYpJTcpO3JldHVybiJaImluIHU/KHUuSCs9dS5aLzEwMHwwLHUuTSs9dS5aJTEwMCxMdSh1KSk6
bih1KX19ZnVuY3Rpb24gcih0LG4sZSxyKXtmb3IodmFyIGksbyx1PTAsYT1uLmxlbmd0aCxjPWUu
bGVuZ3RoO3U8YTspe2lmKHI+PWMpcmV0dXJuLTE7aWYoMzc9PT0oaT1uLmNoYXJDb2RlQXQodSsr
KSkpe2lmKGk9bi5jaGFyQXQodSsrKSwhKG89VFtpIGluIE1nP24uY2hhckF0KHUrKyk6aV0pfHwo
cj1vKHQsZSxyKSk8MClyZXR1cm4tMX1lbHNlIGlmKGkhPWUuY2hhckNvZGVBdChyKyspKXJldHVy
bi0xfXJldHVybiByfXZhciBpPXQuZGF0ZVRpbWUsbz10LmRhdGUsdT10LnRpbWUsYT10LnBlcmlv
ZHMsYz10LmRheXMscz10LnNob3J0RGF5cyxmPXQubW9udGhzLGw9dC5zaG9ydE1vbnRocyxoPUZ1
KGEpLHA9SXUoYSksZD1GdShjKSx2PUl1KGMpLGc9RnUocyksXz1JdShzKSx5PUZ1KGYpLG09SXUo
ZikseD1GdShsKSxiPUl1KGwpLHc9e2E6ZnVuY3Rpb24odCl7cmV0dXJuIHNbdC5nZXREYXkoKV19
LEE6ZnVuY3Rpb24odCl7cmV0dXJuIGNbdC5nZXREYXkoKV19LGI6ZnVuY3Rpb24odCl7cmV0dXJu
IGxbdC5nZXRNb250aCgpXX0sQjpmdW5jdGlvbih0KXtyZXR1cm4gZlt0LmdldE1vbnRoKCldfSxj
Om51bGwsZDp1YSxlOnVhLGY6bGEsSDphYSxJOmNhLGo6c2EsTDpmYSxtOmhhLE06cGEscDpmdW5j
dGlvbih0KXtyZXR1cm4gYVsrKHQuZ2V0SG91cnMoKT49MTIpXX0sUTpZYSxzOkJhLFM6ZGEsdTp2
YSxVOmdhLFY6X2Esdzp5YSxXOm1hLHg6bnVsbCxYOm51bGwseTp4YSxZOmJhLFo6d2EsIiUiOklh
fSxNPXthOmZ1bmN0aW9uKHQpe3JldHVybiBzW3QuZ2V0VVRDRGF5KCldfSxBOmZ1bmN0aW9uKHQp
e3JldHVybiBjW3QuZ2V0VVRDRGF5KCldfSxiOmZ1bmN0aW9uKHQpe3JldHVybiBsW3QuZ2V0VVRD
TW9udGgoKV19LEI6ZnVuY3Rpb24odCl7cmV0dXJuIGZbdC5nZXRVVENNb250aCgpXX0sYzpudWxs
LGQ6TWEsZTpNYSxmOkVhLEg6VGEsSTpOYSxqOmthLEw6U2EsbTpBYSxNOkNhLHA6ZnVuY3Rpb24o
dCl7cmV0dXJuIGFbKyh0LmdldFVUQ0hvdXJzKCk+PTEyKV19LFE6WWEsczpCYSxTOnphLHU6UGEs
VTpSYSxWOkxhLHc6cWEsVzpEYSx4Om51bGwsWDpudWxsLHk6VWEsWTpPYSxaOkZhLCIlIjpJYX0s
VD17YTpmdW5jdGlvbih0LG4sZSl7dmFyIHI9Zy5leGVjKG4uc2xpY2UoZSkpO3JldHVybiByPyh0
Lnc9X1tyWzBdLnRvTG93ZXJDYXNlKCldLGUrclswXS5sZW5ndGgpOi0xfSxBOmZ1bmN0aW9uKHQs
bixlKXt2YXIgcj1kLmV4ZWMobi5zbGljZShlKSk7cmV0dXJuIHI/KHQudz12W3JbMF0udG9Mb3dl
ckNhc2UoKV0sZStyWzBdLmxlbmd0aCk6LTF9LGI6ZnVuY3Rpb24odCxuLGUpe3ZhciByPXguZXhl
YyhuLnNsaWNlKGUpKTtyZXR1cm4gcj8odC5tPWJbclswXS50b0xvd2VyQ2FzZSgpXSxlK3JbMF0u
bGVuZ3RoKTotMX0sQjpmdW5jdGlvbih0LG4sZSl7dmFyIHI9eS5leGVjKG4uc2xpY2UoZSkpO3Jl
dHVybiByPyh0Lm09bVtyWzBdLnRvTG93ZXJDYXNlKCldLGUrclswXS5sZW5ndGgpOi0xfSxjOmZ1
bmN0aW9uKHQsbixlKXtyZXR1cm4gcih0LGksbixlKX0sZDpHdSxlOkd1LGY6ZWEsSDpKdSxJOkp1
LGo6UXUsTDpuYSxtOlp1LE06S3UscDpmdW5jdGlvbih0LG4sZSl7dmFyIHI9aC5leGVjKG4uc2xp
Y2UoZSkpO3JldHVybiByPyh0LnA9cFtyWzBdLnRvTG93ZXJDYXNlKCldLGUrclswXS5sZW5ndGgp
Oi0xfSxROmlhLHM6b2EsUzp0YSx1OkJ1LFU6SHUsVjpqdSx3Oll1LFc6WHUseDpmdW5jdGlvbih0
LG4sZSl7cmV0dXJuIHIodCxvLG4sZSl9LFg6ZnVuY3Rpb24odCxuLGUpe3JldHVybiByKHQsdSxu
LGUpfSx5OiR1LFk6VnUsWjpXdSwiJSI6cmF9O3JldHVybiB3Lng9bihvLHcpLHcuWD1uKHUsdyks
dy5jPW4oaSx3KSxNLng9bihvLE0pLE0uWD1uKHUsTSksTS5jPW4oaSxNKSx7Zm9ybWF0OmZ1bmN0
aW9uKHQpe3ZhciBlPW4odCs9IiIsdyk7cmV0dXJuIGUudG9TdHJpbmc9ZnVuY3Rpb24oKXtyZXR1
cm4gdH0sZX0scGFyc2U6ZnVuY3Rpb24odCl7dmFyIG49ZSh0Kz0iIixSdSk7cmV0dXJuIG4udG9T
dHJpbmc9ZnVuY3Rpb24oKXtyZXR1cm4gdH0sbn0sdXRjRm9ybWF0OmZ1bmN0aW9uKHQpe3ZhciBl
PW4odCs9IiIsTSk7cmV0dXJuIGUudG9TdHJpbmc9ZnVuY3Rpb24oKXtyZXR1cm4gdH0sZX0sdXRj
UGFyc2U6ZnVuY3Rpb24odCl7dmFyIG49ZSh0LEx1KTtyZXR1cm4gbi50b1N0cmluZz1mdW5jdGlv
bigpe3JldHVybiB0fSxufX19ZnVuY3Rpb24gVXUodCxuLGUpe3ZhciByPXQ8MD8iLSI6IiIsaT0o
cj8tdDp0KSsiIixvPWkubGVuZ3RoO3JldHVybiByKyhvPGU/bmV3IEFycmF5KGUtbysxKS5qb2lu
KG4pK2k6aSl9ZnVuY3Rpb24gT3UodCl7cmV0dXJuIHQucmVwbGFjZShrZywiXFwkJiIpfWZ1bmN0
aW9uIEZ1KHQpe3JldHVybiBuZXcgUmVnRXhwKCJeKD86Iit0Lm1hcChPdSkuam9pbigifCIpKyIp
IiwiaSIpfWZ1bmN0aW9uIEl1KHQpe2Zvcih2YXIgbj17fSxlPS0xLHI9dC5sZW5ndGg7KytlPHI7
KW5bdFtlXS50b0xvd2VyQ2FzZSgpXT1lO3JldHVybiBufWZ1bmN0aW9uIFl1KHQsbixlKXt2YXIg
cj1UZy5leGVjKG4uc2xpY2UoZSxlKzEpKTtyZXR1cm4gcj8odC53PStyWzBdLGUrclswXS5sZW5n
dGgpOi0xfWZ1bmN0aW9uIEJ1KHQsbixlKXt2YXIgcj1UZy5leGVjKG4uc2xpY2UoZSxlKzEpKTty
ZXR1cm4gcj8odC51PStyWzBdLGUrclswXS5sZW5ndGgpOi0xfWZ1bmN0aW9uIEh1KHQsbixlKXt2
YXIgcj1UZy5leGVjKG4uc2xpY2UoZSxlKzIpKTtyZXR1cm4gcj8odC5VPStyWzBdLGUrclswXS5s
ZW5ndGgpOi0xfWZ1bmN0aW9uIGp1KHQsbixlKXt2YXIgcj1UZy5leGVjKG4uc2xpY2UoZSxlKzIp
KTtyZXR1cm4gcj8odC5WPStyWzBdLGUrclswXS5sZW5ndGgpOi0xfWZ1bmN0aW9uIFh1KHQsbixl
KXt2YXIgcj1UZy5leGVjKG4uc2xpY2UoZSxlKzIpKTtyZXR1cm4gcj8odC5XPStyWzBdLGUrclsw
XS5sZW5ndGgpOi0xfWZ1bmN0aW9uIFZ1KHQsbixlKXt2YXIgcj1UZy5leGVjKG4uc2xpY2UoZSxl
KzQpKTtyZXR1cm4gcj8odC55PStyWzBdLGUrclswXS5sZW5ndGgpOi0xfWZ1bmN0aW9uICR1KHQs
bixlKXt2YXIgcj1UZy5leGVjKG4uc2xpY2UoZSxlKzIpKTtyZXR1cm4gcj8odC55PStyWzBdKygr
clswXT42OD8xOTAwOjJlMyksZStyWzBdLmxlbmd0aCk6LTF9ZnVuY3Rpb24gV3UodCxuLGUpe3Zh
ciByPS9eKFopfChbKy1dXGRcZCkoPzo6PyhcZFxkKSk/Ly5leGVjKG4uc2xpY2UoZSxlKzYpKTty
ZXR1cm4gcj8odC5aPXJbMV0/MDotKHJbMl0rKHJbM118fCIwMCIpKSxlK3JbMF0ubGVuZ3RoKTot
MX1mdW5jdGlvbiBadSh0LG4sZSl7dmFyIHI9VGcuZXhlYyhuLnNsaWNlKGUsZSsyKSk7cmV0dXJu
IHI/KHQubT1yWzBdLTEsZStyWzBdLmxlbmd0aCk6LTF9ZnVuY3Rpb24gR3UodCxuLGUpe3ZhciBy
PVRnLmV4ZWMobi5zbGljZShlLGUrMikpO3JldHVybiByPyh0LmQ9K3JbMF0sZStyWzBdLmxlbmd0
aCk6LTF9ZnVuY3Rpb24gUXUodCxuLGUpe3ZhciByPVRnLmV4ZWMobi5zbGljZShlLGUrMykpO3Jl
dHVybiByPyh0Lm09MCx0LmQ9K3JbMF0sZStyWzBdLmxlbmd0aCk6LTF9ZnVuY3Rpb24gSnUodCxu
LGUpe3ZhciByPVRnLmV4ZWMobi5zbGljZShlLGUrMikpO3JldHVybiByPyh0Lkg9K3JbMF0sZSty
WzBdLmxlbmd0aCk6LTF9ZnVuY3Rpb24gS3UodCxuLGUpe3ZhciByPVRnLmV4ZWMobi5zbGljZShl
LGUrMikpO3JldHVybiByPyh0Lk09K3JbMF0sZStyWzBdLmxlbmd0aCk6LTF9ZnVuY3Rpb24gdGEo
dCxuLGUpe3ZhciByPVRnLmV4ZWMobi5zbGljZShlLGUrMikpO3JldHVybiByPyh0LlM9K3JbMF0s
ZStyWzBdLmxlbmd0aCk6LTF9ZnVuY3Rpb24gbmEodCxuLGUpe3ZhciByPVRnLmV4ZWMobi5zbGlj
ZShlLGUrMykpO3JldHVybiByPyh0Lkw9K3JbMF0sZStyWzBdLmxlbmd0aCk6LTF9ZnVuY3Rpb24g
ZWEodCxuLGUpe3ZhciByPVRnLmV4ZWMobi5zbGljZShlLGUrNikpO3JldHVybiByPyh0Lkw9TWF0
aC5mbG9vcihyWzBdLzFlMyksZStyWzBdLmxlbmd0aCk6LTF9ZnVuY3Rpb24gcmEodCxuLGUpe3Zh
ciByPU5nLmV4ZWMobi5zbGljZShlLGUrMSkpO3JldHVybiByP2UrclswXS5sZW5ndGg6LTF9ZnVu
Y3Rpb24gaWEodCxuLGUpe3ZhciByPVRnLmV4ZWMobi5zbGljZShlKSk7cmV0dXJuIHI/KHQuUT0r
clswXSxlK3JbMF0ubGVuZ3RoKTotMX1mdW5jdGlvbiBvYSh0LG4sZSl7dmFyIHI9VGcuZXhlYyhu
LnNsaWNlKGUpKTtyZXR1cm4gcj8odC5RPTFlMyorclswXSxlK3JbMF0ubGVuZ3RoKTotMX1mdW5j
dGlvbiB1YSh0LG4pe3JldHVybiBVdSh0LmdldERhdGUoKSxuLDIpfWZ1bmN0aW9uIGFhKHQsbil7
cmV0dXJuIFV1KHQuZ2V0SG91cnMoKSxuLDIpfWZ1bmN0aW9uIGNhKHQsbil7cmV0dXJuIFV1KHQu
Z2V0SG91cnMoKSUxMnx8MTIsbiwyKX1mdW5jdGlvbiBzYSh0LG4pe3JldHVybiBVdSgxK1B2LmNv
dW50KEd2KHQpLHQpLG4sMyl9ZnVuY3Rpb24gZmEodCxuKXtyZXR1cm4gVXUodC5nZXRNaWxsaXNl
Y29uZHMoKSxuLDMpfWZ1bmN0aW9uIGxhKHQsbil7cmV0dXJuIGZhKHQsbikrIjAwMCJ9ZnVuY3Rp
b24gaGEodCxuKXtyZXR1cm4gVXUodC5nZXRNb250aCgpKzEsbiwyKX1mdW5jdGlvbiBwYSh0LG4p
e3JldHVybiBVdSh0LmdldE1pbnV0ZXMoKSxuLDIpfWZ1bmN0aW9uIGRhKHQsbil7cmV0dXJuIFV1
KHQuZ2V0U2Vjb25kcygpLG4sMil9ZnVuY3Rpb24gdmEodCl7dmFyIG49dC5nZXREYXkoKTtyZXR1
cm4gMD09PW4/NzpufWZ1bmN0aW9uIGdhKHQsbil7cmV0dXJuIFV1KEx2LmNvdW50KEd2KHQpLHQp
LG4sMil9ZnVuY3Rpb24gX2EodCxuKXt2YXIgZT10LmdldERheSgpO3JldHVybiB0PWU+PTR8fDA9
PT1lP092KHQpOk92LmNlaWwodCksVXUoT3YuY291bnQoR3YodCksdCkrKDQ9PT1Hdih0KS5nZXRE
YXkoKSksbiwyKX1mdW5jdGlvbiB5YSh0KXtyZXR1cm4gdC5nZXREYXkoKX1mdW5jdGlvbiBtYSh0
LG4pe3JldHVybiBVdShxdi5jb3VudChHdih0KSx0KSxuLDIpfWZ1bmN0aW9uIHhhKHQsbil7cmV0
dXJuIFV1KHQuZ2V0RnVsbFllYXIoKSUxMDAsbiwyKX1mdW5jdGlvbiBiYSh0LG4pe3JldHVybiBV
dSh0LmdldEZ1bGxZZWFyKCklMWU0LG4sNCl9ZnVuY3Rpb24gd2EodCl7dmFyIG49dC5nZXRUaW1l
em9uZU9mZnNldCgpO3JldHVybihuPjA/Ii0iOihuKj0tMSwiKyIpKStVdShuLzYwfDAsIjAiLDIp
K1V1KG4lNjAsIjAiLDIpfWZ1bmN0aW9uIE1hKHQsbil7cmV0dXJuIFV1KHQuZ2V0VVRDRGF0ZSgp
LG4sMil9ZnVuY3Rpb24gVGEodCxuKXtyZXR1cm4gVXUodC5nZXRVVENIb3VycygpLG4sMil9ZnVu
Y3Rpb24gTmEodCxuKXtyZXR1cm4gVXUodC5nZXRVVENIb3VycygpJTEyfHwxMixuLDIpfWZ1bmN0
aW9uIGthKHQsbil7cmV0dXJuIFV1KDErZWcuY291bnQoeGcodCksdCksbiwzKX1mdW5jdGlvbiBT
YSh0LG4pe3JldHVybiBVdSh0LmdldFVUQ01pbGxpc2Vjb25kcygpLG4sMyl9ZnVuY3Rpb24gRWEo
dCxuKXtyZXR1cm4gU2EodCxuKSsiMDAwIn1mdW5jdGlvbiBBYSh0LG4pe3JldHVybiBVdSh0Lmdl
dFVUQ01vbnRoKCkrMSxuLDIpfWZ1bmN0aW9uIENhKHQsbil7cmV0dXJuIFV1KHQuZ2V0VVRDTWlu
dXRlcygpLG4sMil9ZnVuY3Rpb24gemEodCxuKXtyZXR1cm4gVXUodC5nZXRVVENTZWNvbmRzKCks
biwyKX1mdW5jdGlvbiBQYSh0KXt2YXIgbj10LmdldFVUQ0RheSgpO3JldHVybiAwPT09bj83Om59
ZnVuY3Rpb24gUmEodCxuKXtyZXR1cm4gVXUoaWcuY291bnQoeGcodCksdCksbiwyKX1mdW5jdGlv
biBMYSh0LG4pe3ZhciBlPXQuZ2V0VVRDRGF5KCk7cmV0dXJuIHQ9ZT49NHx8MD09PWU/Y2codCk6
Y2cuY2VpbCh0KSxVdShjZy5jb3VudCh4Zyh0KSx0KSsoND09PXhnKHQpLmdldFVUQ0RheSgpKSxu
LDIpfWZ1bmN0aW9uIHFhKHQpe3JldHVybiB0LmdldFVUQ0RheSgpfWZ1bmN0aW9uIERhKHQsbil7
cmV0dXJuIFV1KG9nLmNvdW50KHhnKHQpLHQpLG4sMil9ZnVuY3Rpb24gVWEodCxuKXtyZXR1cm4g
VXUodC5nZXRVVENGdWxsWWVhcigpJTEwMCxuLDIpfWZ1bmN0aW9uIE9hKHQsbil7cmV0dXJuIFV1
KHQuZ2V0VVRDRnVsbFllYXIoKSUxZTQsbiw0KX1mdW5jdGlvbiBGYSgpe3JldHVybiIrMDAwMCJ9
ZnVuY3Rpb24gSWEoKXtyZXR1cm4iJSJ9ZnVuY3Rpb24gWWEodCl7cmV0dXJuK3R9ZnVuY3Rpb24g
QmEodCl7cmV0dXJuIE1hdGguZmxvb3IoK3QvMWUzKX1mdW5jdGlvbiBIYShuKXtyZXR1cm4gYmc9
RHUobiksdC50aW1lRm9ybWF0PWJnLmZvcm1hdCx0LnRpbWVQYXJzZT1iZy5wYXJzZSx0LnV0Y0Zv
cm1hdD1iZy51dGNGb3JtYXQsdC51dGNQYXJzZT1iZy51dGNQYXJzZSxiZ31mdW5jdGlvbiBqYSh0
KXtyZXR1cm4gbmV3IERhdGUodCl9ZnVuY3Rpb24gWGEodCl7cmV0dXJuIHQgaW5zdGFuY2VvZiBE
YXRlPyt0OituZXcgRGF0ZSgrdCl9ZnVuY3Rpb24gVmEodCxuLHIsaSxvLHUsYSxjLHMpe2Z1bmN0
aW9uIGYoZSl7cmV0dXJuKGEoZSk8ZT9nOnUoZSk8ZT9fOm8oZSk8ZT95OmkoZSk8ZT9tOm4oZSk8
ZT9yKGUpPGU/eDpiOnQoZSk8ZT93Ok0pKGUpfWZ1bmN0aW9uIGwobixyLGksbyl7aWYobnVsbD09
biYmKG49MTApLCJudW1iZXIiPT10eXBlb2Ygbil7dmFyIHU9TWF0aC5hYnMoaS1yKS9uLGE9ZShm
dW5jdGlvbih0KXtyZXR1cm4gdFsyXX0pLnJpZ2h0KFQsdSk7YT09PVQubGVuZ3RoPyhvPXAoci9E
ZyxpL0RnLG4pLG49dCk6YT8obz0oYT1UW3UvVFthLTFdWzJdPFRbYV1bMl0vdT9hLTE6YV0pWzFd
LG49YVswXSk6KG89TWF0aC5tYXgocChyLGksbiksMSksbj1jKX1yZXR1cm4gbnVsbD09bz9uOm4u
ZXZlcnkobyl9dmFyIGg9cHUoc3UsYW4pLGQ9aC5pbnZlcnQsdj1oLmRvbWFpbixnPXMoIi4lTCIp
LF89cygiOiVTIikseT1zKCIlSTolTSIpLG09cygiJUkgJXAiKSx4PXMoIiVhICVkIiksYj1zKCIl
YiAlZCIpLHc9cygiJUIiKSxNPXMoIiVZIiksVD1bW2EsMSxDZ10sW2EsNSw1KkNnXSxbYSwxNSwx
NSpDZ10sW2EsMzAsMzAqQ2ddLFt1LDEsemddLFt1LDUsNSp6Z10sW3UsMTUsMTUqemddLFt1LDMw
LDMwKnpnXSxbbywxLFBnXSxbbywzLDMqUGddLFtvLDYsNipQZ10sW28sMTIsMTIqUGddLFtpLDEs
UmddLFtpLDIsMipSZ10sW3IsMSxMZ10sW24sMSxxZ10sW24sMywzKnFnXSxbdCwxLERnXV07cmV0
dXJuIGguaW52ZXJ0PWZ1bmN0aW9uKHQpe3JldHVybiBuZXcgRGF0ZShkKHQpKX0saC5kb21haW49
ZnVuY3Rpb24odCl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/dihndi5jYWxsKHQsWGEpKTp2KCku
bWFwKGphKX0saC50aWNrcz1mdW5jdGlvbih0LG4pe3ZhciBlLHI9digpLGk9clswXSxvPXJbci5s
ZW5ndGgtMV0sdT1vPGk7cmV0dXJuIHUmJihlPWksaT1vLG89ZSksZT1sKHQsaSxvLG4pLGU9ZT9l
LnJhbmdlKGksbysxKTpbXSx1P2UucmV2ZXJzZSgpOmV9LGgudGlja0Zvcm1hdD1mdW5jdGlvbih0
LG4pe3JldHVybiBudWxsPT1uP2Y6cyhuKX0saC5uaWNlPWZ1bmN0aW9uKHQsbil7dmFyIGU9digp
O3JldHVybih0PWwodCxlWzBdLGVbZS5sZW5ndGgtMV0sbikpP3YoX3UoZSx0KSk6aH0saC5jb3B5
PWZ1bmN0aW9uKCl7cmV0dXJuIGh1KGgsVmEodCxuLHIsaSxvLHUsYSxjLHMpKX0saH1mdW5jdGlv
biAkYSh0KXtyZXR1cm4gdC5tYXRjaCgvLns2fS9nKS5tYXAoZnVuY3Rpb24odCl7cmV0dXJuIiMi
K3R9KX1mdW5jdGlvbiBXYSh0KXt2YXIgbj10Lmxlbmd0aDtyZXR1cm4gZnVuY3Rpb24oZSl7cmV0
dXJuIHRbTWF0aC5tYXgoMCxNYXRoLm1pbihuLTEsTWF0aC5mbG9vcihlKm4pKSldfX1mdW5jdGlv
biBaYSh0KXtmdW5jdGlvbiBuKG4pe3ZhciBvPShuLWUpLyhyLWUpO3JldHVybiB0KGk/TWF0aC5t
YXgoMCxNYXRoLm1pbigxLG8pKTpvKX12YXIgZT0wLHI9MSxpPSExO3JldHVybiBuLmRvbWFpbj1m
dW5jdGlvbih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oZT0rdFswXSxyPSt0WzFdLG4pOltl
LHJdfSxuLmNsYW1wPWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhpPSEhdCxu
KTppfSxuLmludGVycG9sYXRvcj1mdW5jdGlvbihlKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8o
dD1lLG4pOnR9LG4uY29weT1mdW5jdGlvbigpe3JldHVybiBaYSh0KS5kb21haW4oW2Uscl0pLmNs
YW1wKGkpfSxkdShuKX1mdW5jdGlvbiBHYSh0KXtyZXR1cm4gZnVuY3Rpb24oKXtyZXR1cm4gdH19
ZnVuY3Rpb24gUWEodCl7cmV0dXJuIHQ+PTE/aV86dDw9LTE/LWlfOk1hdGguYXNpbih0KX1mdW5j
dGlvbiBKYSh0KXtyZXR1cm4gdC5pbm5lclJhZGl1c31mdW5jdGlvbiBLYSh0KXtyZXR1cm4gdC5v
dXRlclJhZGl1c31mdW5jdGlvbiB0Yyh0KXtyZXR1cm4gdC5zdGFydEFuZ2xlfWZ1bmN0aW9uIG5j
KHQpe3JldHVybiB0LmVuZEFuZ2xlfWZ1bmN0aW9uIGVjKHQpe3JldHVybiB0JiZ0LnBhZEFuZ2xl
fWZ1bmN0aW9uIHJjKHQsbixlLHIsaSxvLHUpe3ZhciBhPXQtZSxjPW4tcixzPSh1P286LW8pL25f
KGEqYStjKmMpLGY9cypjLGw9LXMqYSxoPXQrZixwPW4rbCxkPWUrZix2PXIrbCxnPShoK2QpLzIs
Xz0ocCt2KS8yLHk9ZC1oLG09di1wLHg9eSp5K20qbSxiPWktbyx3PWgqdi1kKnAsTT0obTwwPy0x
OjEpKm5fKEpnKDAsYipiKngtdyp3KSksVD0odyptLXkqTSkveCxOPSgtdyp5LW0qTSkveCxrPSh3
Km0reSpNKS94LFM9KC13KnkrbSpNKS94LEU9VC1nLEE9Ti1fLEM9ay1nLHo9Uy1fO3JldHVybiBF
KkUrQSpBPkMqQyt6KnomJihUPWssTj1TKSx7Y3g6VCxjeTpOLHgwMTotZix5MDE6LWwseDExOlQq
KGkvYi0xKSx5MTE6TiooaS9iLTEpfX1mdW5jdGlvbiBpYyh0KXt0aGlzLl9jb250ZXh0PXR9ZnVu
Y3Rpb24gb2ModCl7cmV0dXJuIG5ldyBpYyh0KX1mdW5jdGlvbiB1Yyh0KXtyZXR1cm4gdFswXX1m
dW5jdGlvbiBhYyh0KXtyZXR1cm4gdFsxXX1mdW5jdGlvbiBjYygpe2Z1bmN0aW9uIHQodCl7dmFy
IGEsYyxzLGY9dC5sZW5ndGgsbD0hMTtmb3IobnVsbD09aSYmKHU9byhzPWVlKCkpKSxhPTA7YTw9
ZjsrK2EpIShhPGYmJnIoYz10W2FdLGEsdCkpPT09bCYmKChsPSFsKT91LmxpbmVTdGFydCgpOnUu
bGluZUVuZCgpKSxsJiZ1LnBvaW50KCtuKGMsYSx0KSwrZShjLGEsdCkpO2lmKHMpcmV0dXJuIHU9
bnVsbCxzKyIifHxudWxsfXZhciBuPXVjLGU9YWMscj1HYSghMCksaT1udWxsLG89b2MsdT1udWxs
O3JldHVybiB0Lng9ZnVuY3Rpb24oZSl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KG49ImZ1bmN0
aW9uIj09dHlwZW9mIGU/ZTpHYSgrZSksdCk6bn0sdC55PWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1
bWVudHMubGVuZ3RoPyhlPSJmdW5jdGlvbiI9PXR5cGVvZiBuP246R2EoK24pLHQpOmV9LHQuZGVm
aW5lZD1mdW5jdGlvbihuKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8ocj0iZnVuY3Rpb24iPT10
eXBlb2Ygbj9uOkdhKCEhbiksdCk6cn0sdC5jdXJ2ZT1mdW5jdGlvbihuKXtyZXR1cm4gYXJndW1l
bnRzLmxlbmd0aD8obz1uLG51bGwhPWkmJih1PW8oaSkpLHQpOm99LHQuY29udGV4dD1mdW5jdGlv
bihuKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8obnVsbD09bj9pPXU9bnVsbDp1PW8oaT1uKSx0
KTppfSx0fWZ1bmN0aW9uIHNjKCl7ZnVuY3Rpb24gdCh0KXt2YXIgbixmLGwsaCxwLGQ9dC5sZW5n
dGgsdj0hMSxnPW5ldyBBcnJheShkKSxfPW5ldyBBcnJheShkKTtmb3IobnVsbD09YSYmKHM9Yyhw
PWVlKCkpKSxuPTA7bjw9ZDsrK24pe2lmKCEobjxkJiZ1KGg9dFtuXSxuLHQpKT09PXYpaWYodj0h
dilmPW4scy5hcmVhU3RhcnQoKSxzLmxpbmVTdGFydCgpO2Vsc2V7Zm9yKHMubGluZUVuZCgpLHMu
bGluZVN0YXJ0KCksbD1uLTE7bD49ZjstLWwpcy5wb2ludChnW2xdLF9bbF0pO3MubGluZUVuZCgp
LHMuYXJlYUVuZCgpfXYmJihnW25dPStlKGgsbix0KSxfW25dPStpKGgsbix0KSxzLnBvaW50KHI/
K3IoaCxuLHQpOmdbbl0sbz8rbyhoLG4sdCk6X1tuXSkpfWlmKHApcmV0dXJuIHM9bnVsbCxwKyIi
fHxudWxsfWZ1bmN0aW9uIG4oKXtyZXR1cm4gY2MoKS5kZWZpbmVkKHUpLmN1cnZlKGMpLmNvbnRl
eHQoYSl9dmFyIGU9dWMscj1udWxsLGk9R2EoMCksbz1hYyx1PUdhKCEwKSxhPW51bGwsYz1vYyxz
PW51bGw7cmV0dXJuIHQueD1mdW5jdGlvbihuKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oZT0i
ZnVuY3Rpb24iPT10eXBlb2Ygbj9uOkdhKCtuKSxyPW51bGwsdCk6ZX0sdC54MD1mdW5jdGlvbihu
KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oZT0iZnVuY3Rpb24iPT10eXBlb2Ygbj9uOkdhKCtu
KSx0KTplfSx0LngxPWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhyPW51bGw9
PW4/bnVsbDoiZnVuY3Rpb24iPT10eXBlb2Ygbj9uOkdhKCtuKSx0KTpyfSx0Lnk9ZnVuY3Rpb24o
bil7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KGk9ImZ1bmN0aW9uIj09dHlwZW9mIG4/bjpHYSgr
biksbz1udWxsLHQpOml9LHQueTA9ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/
KGk9ImZ1bmN0aW9uIj09dHlwZW9mIG4/bjpHYSgrbiksdCk6aX0sdC55MT1mdW5jdGlvbihuKXty
ZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8obz1udWxsPT1uP251bGw6ImZ1bmN0aW9uIj09dHlwZW9m
IG4/bjpHYSgrbiksdCk6b30sdC5saW5lWDA9dC5saW5lWTA9ZnVuY3Rpb24oKXtyZXR1cm4gbigp
LngoZSkueShpKX0sdC5saW5lWTE9ZnVuY3Rpb24oKXtyZXR1cm4gbigpLngoZSkueShvKX0sdC5s
aW5lWDE9ZnVuY3Rpb24oKXtyZXR1cm4gbigpLngocikueShpKX0sdC5kZWZpbmVkPWZ1bmN0aW9u
KG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyh1PSJmdW5jdGlvbiI9PXR5cGVvZiBuP246R2Eo
ISFuKSx0KTp1fSx0LmN1cnZlPWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhj
PW4sbnVsbCE9YSYmKHM9YyhhKSksdCk6Y30sdC5jb250ZXh0PWZ1bmN0aW9uKG4pe3JldHVybiBh
cmd1bWVudHMubGVuZ3RoPyhudWxsPT1uP2E9cz1udWxsOnM9YyhhPW4pLHQpOmF9LHR9ZnVuY3Rp
b24gZmModCxuKXtyZXR1cm4gbjx0Py0xOm4+dD8xOm4+PXQ/MDpOYU59ZnVuY3Rpb24gbGModCl7
cmV0dXJuIHR9ZnVuY3Rpb24gaGModCl7dGhpcy5fY3VydmU9dH1mdW5jdGlvbiBwYyh0KXtmdW5j
dGlvbiBuKG4pe3JldHVybiBuZXcgaGModChuKSl9cmV0dXJuIG4uX2N1cnZlPXQsbn1mdW5jdGlv
biBkYyh0KXt2YXIgbj10LmN1cnZlO3JldHVybiB0LmFuZ2xlPXQueCxkZWxldGUgdC54LHQucmFk
aXVzPXQueSxkZWxldGUgdC55LHQuY3VydmU9ZnVuY3Rpb24odCl7cmV0dXJuIGFyZ3VtZW50cy5s
ZW5ndGg/bihwYyh0KSk6bigpLl9jdXJ2ZX0sdH1mdW5jdGlvbiB2Yygpe3JldHVybiBkYyhjYygp
LmN1cnZlKHVfKSl9ZnVuY3Rpb24gZ2MoKXt2YXIgdD1zYygpLmN1cnZlKHVfKSxuPXQuY3VydmUs
ZT10LmxpbmVYMCxyPXQubGluZVgxLGk9dC5saW5lWTAsbz10LmxpbmVZMTtyZXR1cm4gdC5hbmds
ZT10LngsZGVsZXRlIHQueCx0LnN0YXJ0QW5nbGU9dC54MCxkZWxldGUgdC54MCx0LmVuZEFuZ2xl
PXQueDEsZGVsZXRlIHQueDEsdC5yYWRpdXM9dC55LGRlbGV0ZSB0LnksdC5pbm5lclJhZGl1cz10
LnkwLGRlbGV0ZSB0LnkwLHQub3V0ZXJSYWRpdXM9dC55MSxkZWxldGUgdC55MSx0LmxpbmVTdGFy
dEFuZ2xlPWZ1bmN0aW9uKCl7cmV0dXJuIGRjKGUoKSl9LGRlbGV0ZSB0LmxpbmVYMCx0LmxpbmVF
bmRBbmdsZT1mdW5jdGlvbigpe3JldHVybiBkYyhyKCkpfSxkZWxldGUgdC5saW5lWDEsdC5saW5l
SW5uZXJSYWRpdXM9ZnVuY3Rpb24oKXtyZXR1cm4gZGMoaSgpKX0sZGVsZXRlIHQubGluZVkwLHQu
bGluZU91dGVyUmFkaXVzPWZ1bmN0aW9uKCl7cmV0dXJuIGRjKG8oKSl9LGRlbGV0ZSB0LmxpbmVZ
MSx0LmN1cnZlPWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoP24ocGModCkpOm4o
KS5fY3VydmV9LHR9ZnVuY3Rpb24gX2ModCxuKXtyZXR1cm5bKG49K24pKk1hdGguY29zKHQtPU1h
dGguUEkvMiksbipNYXRoLnNpbih0KV19ZnVuY3Rpb24geWModCl7cmV0dXJuIHQuc291cmNlfWZ1
bmN0aW9uIG1jKHQpe3JldHVybiB0LnRhcmdldH1mdW5jdGlvbiB4Yyh0KXtmdW5jdGlvbiBuKCl7
dmFyIG4sYT1hXy5jYWxsKGFyZ3VtZW50cyksYz1lLmFwcGx5KHRoaXMsYSkscz1yLmFwcGx5KHRo
aXMsYSk7aWYodXx8KHU9bj1lZSgpKSx0KHUsK2kuYXBwbHkodGhpcywoYVswXT1jLGEpKSwrby5h
cHBseSh0aGlzLGEpLCtpLmFwcGx5KHRoaXMsKGFbMF09cyxhKSksK28uYXBwbHkodGhpcyxhKSks
bilyZXR1cm4gdT1udWxsLG4rIiJ8fG51bGx9dmFyIGU9eWMscj1tYyxpPXVjLG89YWMsdT1udWxs
O3JldHVybiBuLnNvdXJjZT1mdW5jdGlvbih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oZT10
LG4pOmV9LG4udGFyZ2V0PWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhyPXQs
bik6cn0sbi54PWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhpPSJmdW5jdGlv
biI9PXR5cGVvZiB0P3Q6R2EoK3QpLG4pOml9LG4ueT1mdW5jdGlvbih0KXtyZXR1cm4gYXJndW1l
bnRzLmxlbmd0aD8obz0iZnVuY3Rpb24iPT10eXBlb2YgdD90OkdhKCt0KSxuKTpvfSxuLmNvbnRl
eHQ9ZnVuY3Rpb24odCl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KHU9bnVsbD09dD9udWxsOnQs
bik6dX0sbn1mdW5jdGlvbiBiYyh0LG4sZSxyLGkpe3QubW92ZVRvKG4sZSksdC5iZXppZXJDdXJ2
ZVRvKG49KG4rcikvMixlLG4saSxyLGkpfWZ1bmN0aW9uIHdjKHQsbixlLHIsaSl7dC5tb3ZlVG8o
bixlKSx0LmJlemllckN1cnZlVG8obixlPShlK2kpLzIscixlLHIsaSl9ZnVuY3Rpb24gTWModCxu
LGUscixpKXt2YXIgbz1fYyhuLGUpLHU9X2MobixlPShlK2kpLzIpLGE9X2MocixlKSxjPV9jKHIs
aSk7dC5tb3ZlVG8ob1swXSxvWzFdKSx0LmJlemllckN1cnZlVG8odVswXSx1WzFdLGFbMF0sYVsx
XSxjWzBdLGNbMV0pfWZ1bmN0aW9uIFRjKCl7fWZ1bmN0aW9uIE5jKHQsbixlKXt0Ll9jb250ZXh0
LmJlemllckN1cnZlVG8oKDIqdC5feDArdC5feDEpLzMsKDIqdC5feTArdC5feTEpLzMsKHQuX3gw
KzIqdC5feDEpLzMsKHQuX3kwKzIqdC5feTEpLzMsKHQuX3gwKzQqdC5feDErbikvNiwodC5feTAr
NCp0Ll95MStlKS82KX1mdW5jdGlvbiBrYyh0KXt0aGlzLl9jb250ZXh0PXR9ZnVuY3Rpb24gU2Mo
dCl7dGhpcy5fY29udGV4dD10fWZ1bmN0aW9uIEVjKHQpe3RoaXMuX2NvbnRleHQ9dH1mdW5jdGlv
biBBYyh0LG4pe3RoaXMuX2Jhc2lzPW5ldyBrYyh0KSx0aGlzLl9iZXRhPW59ZnVuY3Rpb24gQ2Mo
dCxuLGUpe3QuX2NvbnRleHQuYmV6aWVyQ3VydmVUbyh0Ll94MSt0Ll9rKih0Ll94Mi10Ll94MCks
dC5feTErdC5fayoodC5feTItdC5feTApLHQuX3gyK3QuX2sqKHQuX3gxLW4pLHQuX3kyK3QuX2sq
KHQuX3kxLWUpLHQuX3gyLHQuX3kyKX1mdW5jdGlvbiB6Yyh0LG4pe3RoaXMuX2NvbnRleHQ9dCx0
aGlzLl9rPSgxLW4pLzZ9ZnVuY3Rpb24gUGModCxuKXt0aGlzLl9jb250ZXh0PXQsdGhpcy5faz0o
MS1uKS82fWZ1bmN0aW9uIFJjKHQsbil7dGhpcy5fY29udGV4dD10LHRoaXMuX2s9KDEtbikvNn1m
dW5jdGlvbiBMYyh0LG4sZSl7dmFyIHI9dC5feDEsaT10Ll95MSxvPXQuX3gyLHU9dC5feTI7aWYo
dC5fbDAxX2E+ZV8pe3ZhciBhPTIqdC5fbDAxXzJhKzMqdC5fbDAxX2EqdC5fbDEyX2ErdC5fbDEy
XzJhLGM9Myp0Ll9sMDFfYSoodC5fbDAxX2ErdC5fbDEyX2EpO3I9KHIqYS10Ll94MCp0Ll9sMTJf
MmErdC5feDIqdC5fbDAxXzJhKS9jLGk9KGkqYS10Ll95MCp0Ll9sMTJfMmErdC5feTIqdC5fbDAx
XzJhKS9jfWlmKHQuX2wyM19hPmVfKXt2YXIgcz0yKnQuX2wyM18yYSszKnQuX2wyM19hKnQuX2wx
Ml9hK3QuX2wxMl8yYSxmPTMqdC5fbDIzX2EqKHQuX2wyM19hK3QuX2wxMl9hKTtvPShvKnMrdC5f
eDEqdC5fbDIzXzJhLW4qdC5fbDEyXzJhKS9mLHU9KHUqcyt0Ll95MSp0Ll9sMjNfMmEtZSp0Ll9s
MTJfMmEpL2Z9dC5fY29udGV4dC5iZXppZXJDdXJ2ZVRvKHIsaSxvLHUsdC5feDIsdC5feTIpfWZ1
bmN0aW9uIHFjKHQsbil7dGhpcy5fY29udGV4dD10LHRoaXMuX2FscGhhPW59ZnVuY3Rpb24gRGMo
dCxuKXt0aGlzLl9jb250ZXh0PXQsdGhpcy5fYWxwaGE9bn1mdW5jdGlvbiBVYyh0LG4pe3RoaXMu
X2NvbnRleHQ9dCx0aGlzLl9hbHBoYT1ufWZ1bmN0aW9uIE9jKHQpe3RoaXMuX2NvbnRleHQ9dH1m
dW5jdGlvbiBGYyh0KXtyZXR1cm4gdDwwPy0xOjF9ZnVuY3Rpb24gSWModCxuLGUpe3ZhciByPXQu
X3gxLXQuX3gwLGk9bi10Ll94MSxvPSh0Ll95MS10Ll95MCkvKHJ8fGk8MCYmLTApLHU9KGUtdC5f
eTEpLyhpfHxyPDAmJi0wKSxhPShvKmkrdSpyKS8ocitpKTtyZXR1cm4oRmMobykrRmModSkpKk1h
dGgubWluKE1hdGguYWJzKG8pLE1hdGguYWJzKHUpLC41Kk1hdGguYWJzKGEpKXx8MH1mdW5jdGlv
biBZYyh0LG4pe3ZhciBlPXQuX3gxLXQuX3gwO3JldHVybiBlPygzKih0Ll95MS10Ll95MCkvZS1u
KS8yOm59ZnVuY3Rpb24gQmModCxuLGUpe3ZhciByPXQuX3gwLGk9dC5feTAsbz10Ll94MSx1PXQu
X3kxLGE9KG8tcikvMzt0Ll9jb250ZXh0LmJlemllckN1cnZlVG8ocithLGkrYSpuLG8tYSx1LWEq
ZSxvLHUpfWZ1bmN0aW9uIEhjKHQpe3RoaXMuX2NvbnRleHQ9dH1mdW5jdGlvbiBqYyh0KXt0aGlz
Ll9jb250ZXh0PW5ldyBYYyh0KX1mdW5jdGlvbiBYYyh0KXt0aGlzLl9jb250ZXh0PXR9ZnVuY3Rp
b24gVmModCl7dGhpcy5fY29udGV4dD10fWZ1bmN0aW9uICRjKHQpe3ZhciBuLGUscj10Lmxlbmd0
aC0xLGk9bmV3IEFycmF5KHIpLG89bmV3IEFycmF5KHIpLHU9bmV3IEFycmF5KHIpO2ZvcihpWzBd
PTAsb1swXT0yLHVbMF09dFswXSsyKnRbMV0sbj0xO248ci0xOysrbilpW25dPTEsb1tuXT00LHVb
bl09NCp0W25dKzIqdFtuKzFdO2ZvcihpW3ItMV09MixvW3ItMV09Nyx1W3ItMV09OCp0W3ItMV0r
dFtyXSxuPTE7bjxyOysrbillPWlbbl0vb1tuLTFdLG9bbl0tPWUsdVtuXS09ZSp1W24tMV07Zm9y
KGlbci0xXT11W3ItMV0vb1tyLTFdLG49ci0yO24+PTA7LS1uKWlbbl09KHVbbl0taVtuKzFdKS9v
W25dO2ZvcihvW3ItMV09KHRbcl0raVtyLTFdKS8yLG49MDtuPHItMTsrK24pb1tuXT0yKnRbbisx
XS1pW24rMV07cmV0dXJuW2ksb119ZnVuY3Rpb24gV2ModCxuKXt0aGlzLl9jb250ZXh0PXQsdGhp
cy5fdD1ufWZ1bmN0aW9uIFpjKHQsbil7aWYoKGk9dC5sZW5ndGgpPjEpZm9yKHZhciBlLHIsaSxv
PTEsdT10W25bMF1dLGE9dS5sZW5ndGg7bzxpOysrbylmb3Iocj11LHU9dFtuW29dXSxlPTA7ZTxh
OysrZSl1W2VdWzFdKz11W2VdWzBdPWlzTmFOKHJbZV1bMV0pP3JbZV1bMF06cltlXVsxXX1mdW5j
dGlvbiBHYyh0KXtmb3IodmFyIG49dC5sZW5ndGgsZT1uZXcgQXJyYXkobik7LS1uPj0wOyllW25d
PW47cmV0dXJuIGV9ZnVuY3Rpb24gUWModCxuKXtyZXR1cm4gdFtuXX1mdW5jdGlvbiBKYyh0KXt2
YXIgbj10Lm1hcChLYyk7cmV0dXJuIEdjKHQpLnNvcnQoZnVuY3Rpb24odCxlKXtyZXR1cm4gblt0
XS1uW2VdfSl9ZnVuY3Rpb24gS2ModCl7Zm9yKHZhciBuLGU9MCxyPS0xLGk9dC5sZW5ndGg7Kyty
PGk7KShuPSt0W3JdWzFdKSYmKGUrPW4pO3JldHVybiBlfWZ1bmN0aW9uIHRzKHQpe3JldHVybiBm
dW5jdGlvbigpe3JldHVybiB0fX1mdW5jdGlvbiBucyh0KXtyZXR1cm4gdFswXX1mdW5jdGlvbiBl
cyh0KXtyZXR1cm4gdFsxXX1mdW5jdGlvbiBycygpe3RoaXMuXz1udWxsfWZ1bmN0aW9uIGlzKHQp
e3QuVT10LkM9dC5MPXQuUj10LlA9dC5OPW51bGx9ZnVuY3Rpb24gb3ModCxuKXt2YXIgZT1uLHI9
bi5SLGk9ZS5VO2k/aS5MPT09ZT9pLkw9cjppLlI9cjp0Ll89cixyLlU9aSxlLlU9cixlLlI9ci5M
LGUuUiYmKGUuUi5VPWUpLHIuTD1lfWZ1bmN0aW9uIHVzKHQsbil7dmFyIGU9bixyPW4uTCxpPWUu
VTtpP2kuTD09PWU/aS5MPXI6aS5SPXI6dC5fPXIsci5VPWksZS5VPXIsZS5MPXIuUixlLkwmJihl
LkwuVT1lKSxyLlI9ZX1mdW5jdGlvbiBhcyh0KXtmb3IoO3QuTDspdD10Lkw7cmV0dXJuIHR9ZnVu
Y3Rpb24gY3ModCxuLGUscil7dmFyIGk9W251bGwsbnVsbF0sbz1EXy5wdXNoKGkpLTE7cmV0dXJu
IGkubGVmdD10LGkucmlnaHQ9bixlJiZmcyhpLHQsbixlKSxyJiZmcyhpLG4sdCxyKSxMX1t0Lmlu
ZGV4XS5oYWxmZWRnZXMucHVzaChvKSxMX1tuLmluZGV4XS5oYWxmZWRnZXMucHVzaChvKSxpfWZ1
bmN0aW9uIHNzKHQsbixlKXt2YXIgcj1bbixlXTtyZXR1cm4gci5sZWZ0PXQscn1mdW5jdGlvbiBm
cyh0LG4sZSxyKXt0WzBdfHx0WzFdP3QubGVmdD09PWU/dFsxXT1yOnRbMF09cjoodFswXT1yLHQu
bGVmdD1uLHQucmlnaHQ9ZSl9ZnVuY3Rpb24gbHModCxuLGUscixpKXt2YXIgbyx1PXRbMF0sYT10
WzFdLGM9dVswXSxzPXVbMV0sZj0wLGw9MSxoPWFbMF0tYyxwPWFbMV0tcztpZihvPW4tYyxofHwh
KG8+MCkpe2lmKG8vPWgsaDwwKXtpZihvPGYpcmV0dXJuO288bCYmKGw9byl9ZWxzZSBpZihoPjAp
e2lmKG8+bClyZXR1cm47bz5mJiYoZj1vKX1pZihvPXItYyxofHwhKG88MCkpe2lmKG8vPWgsaDww
KXtpZihvPmwpcmV0dXJuO28+ZiYmKGY9byl9ZWxzZSBpZihoPjApe2lmKG88ZilyZXR1cm47bzxs
JiYobD1vKX1pZihvPWUtcyxwfHwhKG8+MCkpe2lmKG8vPXAscDwwKXtpZihvPGYpcmV0dXJuO288
bCYmKGw9byl9ZWxzZSBpZihwPjApe2lmKG8+bClyZXR1cm47bz5mJiYoZj1vKX1pZihvPWktcyxw
fHwhKG88MCkpe2lmKG8vPXAscDwwKXtpZihvPmwpcmV0dXJuO28+ZiYmKGY9byl9ZWxzZSBpZihw
PjApe2lmKG88ZilyZXR1cm47bzxsJiYobD1vKX1yZXR1cm4hKGY+MHx8bDwxKXx8KGY+MCYmKHRb
MF09W2MrZipoLHMrZipwXSksbDwxJiYodFsxXT1bYytsKmgscytsKnBdKSwhMCl9fX19fWZ1bmN0
aW9uIGhzKHQsbixlLHIsaSl7dmFyIG89dFsxXTtpZihvKXJldHVybiEwO3ZhciB1LGEsYz10WzBd
LHM9dC5sZWZ0LGY9dC5yaWdodCxsPXNbMF0saD1zWzFdLHA9ZlswXSxkPWZbMV0sdj0obCtwKS8y
LGc9KGgrZCkvMjtpZihkPT09aCl7aWYodjxufHx2Pj1yKXJldHVybjtpZihsPnApe2lmKGMpe2lm
KGNbMV0+PWkpcmV0dXJufWVsc2UgYz1bdixlXTtvPVt2LGldfWVsc2V7aWYoYyl7aWYoY1sxXTxl
KXJldHVybn1lbHNlIGM9W3YsaV07bz1bdixlXX19ZWxzZSBpZih1PShsLXApLyhkLWgpLGE9Zy11
KnYsdTwtMXx8dT4xKWlmKGw+cCl7aWYoYyl7aWYoY1sxXT49aSlyZXR1cm59ZWxzZSBjPVsoZS1h
KS91LGVdO289WyhpLWEpL3UsaV19ZWxzZXtpZihjKXtpZihjWzFdPGUpcmV0dXJufWVsc2UgYz1b
KGktYSkvdSxpXTtvPVsoZS1hKS91LGVdfWVsc2UgaWYoaDxkKXtpZihjKXtpZihjWzBdPj1yKXJl
dHVybn1lbHNlIGM9W24sdSpuK2FdO289W3IsdSpyK2FdfWVsc2V7aWYoYyl7aWYoY1swXTxuKXJl
dHVybn1lbHNlIGM9W3IsdSpyK2FdO289W24sdSpuK2FdfXJldHVybiB0WzBdPWMsdFsxXT1vLCEw
fWZ1bmN0aW9uIHBzKHQsbil7dmFyIGU9dC5zaXRlLHI9bi5sZWZ0LGk9bi5yaWdodDtyZXR1cm4g
ZT09PWkmJihpPXIscj1lKSxpP01hdGguYXRhbjIoaVsxXS1yWzFdLGlbMF0tclswXSk6KGU9PT1y
PyhyPW5bMV0saT1uWzBdKToocj1uWzBdLGk9blsxXSksTWF0aC5hdGFuMihyWzBdLWlbMF0saVsx
XS1yWzFdKSl9ZnVuY3Rpb24gZHModCxuKXtyZXR1cm4gblsrKG4ubGVmdCE9PXQuc2l0ZSldfWZ1
bmN0aW9uIHZzKHQsbil7cmV0dXJuIG5bKyhuLmxlZnQ9PT10LnNpdGUpXX1mdW5jdGlvbiBncyh0
KXt2YXIgbj10LlAsZT10Lk47aWYobiYmZSl7dmFyIHI9bi5zaXRlLGk9dC5zaXRlLG89ZS5zaXRl
O2lmKHIhPT1vKXt2YXIgdT1pWzBdLGE9aVsxXSxjPXJbMF0tdSxzPXJbMV0tYSxmPW9bMF0tdSxs
PW9bMV0tYSxoPTIqKGMqbC1zKmYpO2lmKCEoaD49LUlfKSl7dmFyIHA9YypjK3MqcyxkPWYqZits
Kmwsdj0obCpwLXMqZCkvaCxnPShjKmQtZipwKS9oLF89VV8ucG9wKCl8fG5ldyBmdW5jdGlvbigp
e2lzKHRoaXMpLHRoaXMueD10aGlzLnk9dGhpcy5hcmM9dGhpcy5zaXRlPXRoaXMuY3k9bnVsbH07
Xy5hcmM9dCxfLnNpdGU9aSxfLng9dit1LF8ueT0oXy5jeT1nK2EpK01hdGguc3FydCh2KnYrZypn
KSx0LmNpcmNsZT1fO2Zvcih2YXIgeT1udWxsLG09cV8uXzttOylpZihfLnk8bS55fHxfLnk9PT1t
LnkmJl8ueDw9bS54KXtpZighbS5MKXt5PW0uUDticmVha31tPW0uTH1lbHNle2lmKCFtLlIpe3k9
bTticmVha31tPW0uUn1xXy5pbnNlcnQoeSxfKSx5fHwoUF89Xyl9fX19ZnVuY3Rpb24gX3ModCl7
dmFyIG49dC5jaXJjbGU7biYmKG4uUHx8KFBfPW4uTikscV8ucmVtb3ZlKG4pLFVfLnB1c2gobiks
aXMobiksdC5jaXJjbGU9bnVsbCl9ZnVuY3Rpb24geXModCl7dmFyIG49T18ucG9wKCl8fG5ldyBm
dW5jdGlvbigpe2lzKHRoaXMpLHRoaXMuZWRnZT10aGlzLnNpdGU9dGhpcy5jaXJjbGU9bnVsbH07
cmV0dXJuIG4uc2l0ZT10LG59ZnVuY3Rpb24gbXModCl7X3ModCksUl8ucmVtb3ZlKHQpLE9fLnB1
c2godCksaXModCl9ZnVuY3Rpb24geHModCl7dmFyIG49dC5jaXJjbGUsZT1uLngscj1uLmN5LGk9
W2Uscl0sbz10LlAsdT10Lk4sYT1bdF07bXModCk7Zm9yKHZhciBjPW87Yy5jaXJjbGUmJk1hdGgu
YWJzKGUtYy5jaXJjbGUueCk8Rl8mJk1hdGguYWJzKHItYy5jaXJjbGUuY3kpPEZfOylvPWMuUCxh
LnVuc2hpZnQoYyksbXMoYyksYz1vO2EudW5zaGlmdChjKSxfcyhjKTtmb3IodmFyIHM9dTtzLmNp
cmNsZSYmTWF0aC5hYnMoZS1zLmNpcmNsZS54KTxGXyYmTWF0aC5hYnMoci1zLmNpcmNsZS5jeSk8
Rl87KXU9cy5OLGEucHVzaChzKSxtcyhzKSxzPXU7YS5wdXNoKHMpLF9zKHMpO3ZhciBmLGw9YS5s
ZW5ndGg7Zm9yKGY9MTtmPGw7KytmKXM9YVtmXSxjPWFbZi0xXSxmcyhzLmVkZ2UsYy5zaXRlLHMu
c2l0ZSxpKTtjPWFbMF0sKHM9YVtsLTFdKS5lZGdlPWNzKGMuc2l0ZSxzLnNpdGUsbnVsbCxpKSxn
cyhjKSxncyhzKX1mdW5jdGlvbiBicyh0KXtmb3IodmFyIG4sZSxyLGksbz10WzBdLHU9dFsxXSxh
PVJfLl87YTspaWYoKHI9d3MoYSx1KS1vKT5GXylhPWEuTDtlbHNle2lmKCEoKGk9by1mdW5jdGlv
bih0LG4pe3ZhciBlPXQuTjtpZihlKXJldHVybiB3cyhlLG4pO3ZhciByPXQuc2l0ZTtyZXR1cm4g
clsxXT09PW4/clswXToxLzB9KGEsdSkpPkZfKSl7cj4tRl8/KG49YS5QLGU9YSk6aT4tRl8/KG49
YSxlPWEuTik6bj1lPWE7YnJlYWt9aWYoIWEuUil7bj1hO2JyZWFrfWE9YS5SfShmdW5jdGlvbih0
KXtMX1t0LmluZGV4XT17c2l0ZTp0LGhhbGZlZGdlczpbXX19KSh0KTt2YXIgYz15cyh0KTtpZihS
Xy5pbnNlcnQobixjKSxufHxlKXtpZihuPT09ZSlyZXR1cm4gX3MobiksZT15cyhuLnNpdGUpLFJf
Lmluc2VydChjLGUpLGMuZWRnZT1lLmVkZ2U9Y3Mobi5zaXRlLGMuc2l0ZSksZ3Mobiksdm9pZCBn
cyhlKTtpZihlKXtfcyhuKSxfcyhlKTt2YXIgcz1uLnNpdGUsZj1zWzBdLGw9c1sxXSxoPXRbMF0t
ZixwPXRbMV0tbCxkPWUuc2l0ZSx2PWRbMF0tZixnPWRbMV0tbCxfPTIqKGgqZy1wKnYpLHk9aCpo
K3AqcCxtPXYqditnKmcseD1bKGcqeS1wKm0pL18rZiwoaCptLXYqeSkvXytsXTtmcyhlLmVkZ2Us
cyxkLHgpLGMuZWRnZT1jcyhzLHQsbnVsbCx4KSxlLmVkZ2U9Y3ModCxkLG51bGwseCksZ3Mobiks
Z3MoZSl9ZWxzZSBjLmVkZ2U9Y3Mobi5zaXRlLGMuc2l0ZSl9fWZ1bmN0aW9uIHdzKHQsbil7dmFy
IGU9dC5zaXRlLHI9ZVswXSxpPWVbMV0sbz1pLW47aWYoIW8pcmV0dXJuIHI7dmFyIHU9dC5QO2lm
KCF1KXJldHVybi0xLzA7dmFyIGE9KGU9dS5zaXRlKVswXSxjPWVbMV0scz1jLW47aWYoIXMpcmV0
dXJuIGE7dmFyIGY9YS1yLGw9MS9vLTEvcyxoPWYvcztyZXR1cm4gbD8oLWgrTWF0aC5zcXJ0KGgq
aC0yKmwqKGYqZi8oLTIqcyktYytzLzIraS1vLzIpKSkvbCtyOihyK2EpLzJ9ZnVuY3Rpb24gTXMo
dCxuLGUpe3JldHVybih0WzBdLWVbMF0pKihuWzFdLXRbMV0pLSh0WzBdLW5bMF0pKihlWzFdLXRb
MV0pfWZ1bmN0aW9uIFRzKHQsbil7cmV0dXJuIG5bMV0tdFsxXXx8blswXS10WzBdfWZ1bmN0aW9u
IE5zKHQsbil7dmFyIGUscixpLG89dC5zb3J0KFRzKS5wb3AoKTtmb3IoRF89W10sTF89bmV3IEFy
cmF5KHQubGVuZ3RoKSxSXz1uZXcgcnMscV89bmV3IHJzOzspaWYoaT1QXyxvJiYoIWl8fG9bMV08
aS55fHxvWzFdPT09aS55JiZvWzBdPGkueCkpb1swXT09PWUmJm9bMV09PT1yfHwoYnMobyksZT1v
WzBdLHI9b1sxXSksbz10LnBvcCgpO2Vsc2V7aWYoIWkpYnJlYWs7eHMoaS5hcmMpfWlmKGZ1bmN0
aW9uKCl7Zm9yKHZhciB0LG4sZSxyLGk9MCxvPUxfLmxlbmd0aDtpPG87KytpKWlmKCh0PUxfW2ld
KSYmKHI9KG49dC5oYWxmZWRnZXMpLmxlbmd0aCkpe3ZhciB1PW5ldyBBcnJheShyKSxhPW5ldyBB
cnJheShyKTtmb3IoZT0wO2U8cjsrK2UpdVtlXT1lLGFbZV09cHModCxEX1tuW2VdXSk7Zm9yKHUu
c29ydChmdW5jdGlvbih0LG4pe3JldHVybiBhW25dLWFbdF19KSxlPTA7ZTxyOysrZSlhW2VdPW5b
dVtlXV07Zm9yKGU9MDtlPHI7KytlKW5bZV09YVtlXX19KCksbil7dmFyIHU9K25bMF1bMF0sYT0r
blswXVsxXSxjPStuWzFdWzBdLHM9K25bMV1bMV07KGZ1bmN0aW9uKHQsbixlLHIpe2Zvcih2YXIg
aSxvPURfLmxlbmd0aDtvLS07KWhzKGk9RF9bb10sdCxuLGUscikmJmxzKGksdCxuLGUscikmJihN
YXRoLmFicyhpWzBdWzBdLWlbMV1bMF0pPkZffHxNYXRoLmFicyhpWzBdWzFdLWlbMV1bMV0pPkZf
KXx8ZGVsZXRlIERfW29dfSkodSxhLGMscyksZnVuY3Rpb24odCxuLGUscil7dmFyIGksbyx1LGEs
YyxzLGYsbCxoLHAsZCx2LGc9TF8ubGVuZ3RoLF89ITA7Zm9yKGk9MDtpPGc7KytpKWlmKG89TF9b
aV0pe2Zvcih1PW8uc2l0ZSxhPShjPW8uaGFsZmVkZ2VzKS5sZW5ndGg7YS0tOylEX1tjW2FdXXx8
Yy5zcGxpY2UoYSwxKTtmb3IoYT0wLHM9Yy5sZW5ndGg7YTxzOylkPShwPXZzKG8sRF9bY1thXV0p
KVswXSx2PXBbMV0sbD0oZj1kcyhvLERfW2NbKythJXNdXSkpWzBdLGg9ZlsxXSwoTWF0aC5hYnMo
ZC1sKT5GX3x8TWF0aC5hYnModi1oKT5GXykmJihjLnNwbGljZShhLDAsRF8ucHVzaChzcyh1LHAs
TWF0aC5hYnMoZC10KTxGXyYmci12PkZfP1t0LE1hdGguYWJzKGwtdCk8Rl8/aDpyXTpNYXRoLmFi
cyh2LXIpPEZfJiZlLWQ+Rl8/W01hdGguYWJzKGgtcik8Rl8/bDplLHJdOk1hdGguYWJzKGQtZSk8
Rl8mJnYtbj5GXz9bZSxNYXRoLmFicyhsLWUpPEZfP2g6bl06TWF0aC5hYnModi1uKTxGXyYmZC10
PkZfP1tNYXRoLmFicyhoLW4pPEZfP2w6dCxuXTpudWxsKSktMSksKytzKTtzJiYoXz0hMSl9aWYo
Xyl7dmFyIHksbSx4LGI9MS8wO2ZvcihpPTAsXz1udWxsO2k8ZzsrK2kpKG89TF9baV0pJiYoeD0o
eT0odT1vLnNpdGUpWzBdLXQpKnkrKG09dVsxXS1uKSptKTxiJiYoYj14LF89byk7aWYoXyl7dmFy
IHc9W3Qsbl0sTT1bdCxyXSxUPVtlLHJdLE49W2Usbl07Xy5oYWxmZWRnZXMucHVzaChEXy5wdXNo
KHNzKHU9Xy5zaXRlLHcsTSkpLTEsRF8ucHVzaChzcyh1LE0sVCkpLTEsRF8ucHVzaChzcyh1LFQs
TikpLTEsRF8ucHVzaChzcyh1LE4sdykpLTEpfX1mb3IoaT0wO2k8ZzsrK2kpKG89TF9baV0pJiYo
by5oYWxmZWRnZXMubGVuZ3RofHxkZWxldGUgTF9baV0pfSh1LGEsYyxzKX10aGlzLmVkZ2VzPURf
LHRoaXMuY2VsbHM9TF8sUl89cV89RF89TF89bnVsbH1mdW5jdGlvbiBrcyh0KXtyZXR1cm4gZnVu
Y3Rpb24oKXtyZXR1cm4gdH19ZnVuY3Rpb24gU3ModCxuLGUpe3RoaXMuaz10LHRoaXMueD1uLHRo
aXMueT1lfWZ1bmN0aW9uIEVzKHQpe3JldHVybiB0Ll9fem9vbXx8WV99ZnVuY3Rpb24gQXMoKXt0
LmV2ZW50LnN0b3BJbW1lZGlhdGVQcm9wYWdhdGlvbigpfWZ1bmN0aW9uIENzKCl7dC5ldmVudC5w
cmV2ZW50RGVmYXVsdCgpLHQuZXZlbnQuc3RvcEltbWVkaWF0ZVByb3BhZ2F0aW9uKCl9ZnVuY3Rp
b24genMoKXtyZXR1cm4hdC5ldmVudC5idXR0b259ZnVuY3Rpb24gUHMoKXt2YXIgdCxuLGU9dGhp
cztyZXR1cm4gZSBpbnN0YW5jZW9mIFNWR0VsZW1lbnQ/KHQ9KGU9ZS5vd25lclNWR0VsZW1lbnR8
fGUpLndpZHRoLmJhc2VWYWwudmFsdWUsbj1lLmhlaWdodC5iYXNlVmFsLnZhbHVlKToodD1lLmNs
aWVudFdpZHRoLG49ZS5jbGllbnRIZWlnaHQpLFtbMCwwXSxbdCxuXV19ZnVuY3Rpb24gUnMoKXty
ZXR1cm4gdGhpcy5fX3pvb218fFlffWZ1bmN0aW9uIExzKCl7cmV0dXJuLXQuZXZlbnQuZGVsdGFZ
Kih0LmV2ZW50LmRlbHRhTW9kZT8xMjA6MSkvNTAwfWZ1bmN0aW9uIHFzKCl7cmV0dXJuIm9udG91
Y2hzdGFydCJpbiB0aGlzfWZ1bmN0aW9uIERzKHQsbixlKXt2YXIgcj10LmludmVydFgoblswXVsw
XSktZVswXVswXSxpPXQuaW52ZXJ0WChuWzFdWzBdKS1lWzFdWzBdLG89dC5pbnZlcnRZKG5bMF1b
MV0pLWVbMF1bMV0sdT10LmludmVydFkoblsxXVsxXSktZVsxXVsxXTtyZXR1cm4gdC50cmFuc2xh
dGUoaT5yPyhyK2kpLzI6TWF0aC5taW4oMCxyKXx8TWF0aC5tYXgoMCxpKSx1Pm8/KG8rdSkvMjpN
YXRoLm1pbigwLG8pfHxNYXRoLm1heCgwLHUpKX12YXIgVXM9ZShuKSxPcz1Vcy5yaWdodCxGcz1V
cy5sZWZ0LElzPUFycmF5LnByb3RvdHlwZSxZcz1Jcy5zbGljZSxCcz1Jcy5tYXAsSHM9TWF0aC5z
cXJ0KDUwKSxqcz1NYXRoLnNxcnQoMTApLFhzPU1hdGguc3FydCgyKSxWcz1BcnJheS5wcm90b3R5
cGUuc2xpY2UsJHM9MSxXcz0yLFpzPTMsR3M9NCxRcz0xZS02LEpzPXt2YWx1ZTpmdW5jdGlvbigp
e319O2sucHJvdG90eXBlPU4ucHJvdG90eXBlPXtjb25zdHJ1Y3RvcjprLG9uOmZ1bmN0aW9uKHQs
bil7dmFyIGUscj10aGlzLl8saT1mdW5jdGlvbih0LG4pe3JldHVybiB0LnRyaW0oKS5zcGxpdCgv
XnxccysvKS5tYXAoZnVuY3Rpb24odCl7dmFyIGU9IiIscj10LmluZGV4T2YoIi4iKTtpZihyPj0w
JiYoZT10LnNsaWNlKHIrMSksdD10LnNsaWNlKDAscikpLHQmJiFuLmhhc093blByb3BlcnR5KHQp
KXRocm93IG5ldyBFcnJvcigidW5rbm93biB0eXBlOiAiK3QpO3JldHVybnt0eXBlOnQsbmFtZTpl
fX0pfSh0KyIiLHIpLG89LTEsdT1pLmxlbmd0aDt7aWYoIShhcmd1bWVudHMubGVuZ3RoPDIpKXtp
ZihudWxsIT1uJiYiZnVuY3Rpb24iIT10eXBlb2Ygbil0aHJvdyBuZXcgRXJyb3IoImludmFsaWQg
Y2FsbGJhY2s6ICIrbik7Zm9yKDsrK288dTspaWYoZT0odD1pW29dKS50eXBlKXJbZV09UyhyW2Vd
LHQubmFtZSxuKTtlbHNlIGlmKG51bGw9PW4pZm9yKGUgaW4gcilyW2VdPVMocltlXSx0Lm5hbWUs
bnVsbCk7cmV0dXJuIHRoaXN9Zm9yKDsrK288dTspaWYoKGU9KHQ9aVtvXSkudHlwZSkmJihlPWZ1
bmN0aW9uKHQsbil7Zm9yKHZhciBlLHI9MCxpPXQubGVuZ3RoO3I8aTsrK3IpaWYoKGU9dFtyXSku
bmFtZT09PW4pcmV0dXJuIGUudmFsdWV9KHJbZV0sdC5uYW1lKSkpcmV0dXJuIGV9fSxjb3B5OmZ1
bmN0aW9uKCl7dmFyIHQ9e30sbj10aGlzLl87Zm9yKHZhciBlIGluIG4pdFtlXT1uW2VdLnNsaWNl
KCk7cmV0dXJuIG5ldyBrKHQpfSxjYWxsOmZ1bmN0aW9uKHQsbil7aWYoKGU9YXJndW1lbnRzLmxl
bmd0aC0yKT4wKWZvcih2YXIgZSxyLGk9bmV3IEFycmF5KGUpLG89MDtvPGU7KytvKWlbb109YXJn
dW1lbnRzW28rMl07aWYoIXRoaXMuXy5oYXNPd25Qcm9wZXJ0eSh0KSl0aHJvdyBuZXcgRXJyb3Io
InVua25vd24gdHlwZTogIit0KTtmb3Iobz0wLGU9KHI9dGhpcy5fW3RdKS5sZW5ndGg7bzxlOysr
bylyW29dLnZhbHVlLmFwcGx5KG4saSl9LGFwcGx5OmZ1bmN0aW9uKHQsbixlKXtpZighdGhpcy5f
Lmhhc093blByb3BlcnR5KHQpKXRocm93IG5ldyBFcnJvcigidW5rbm93biB0eXBlOiAiK3QpO2Zv
cih2YXIgcj10aGlzLl9bdF0saT0wLG89ci5sZW5ndGg7aTxvOysraSlyW2ldLnZhbHVlLmFwcGx5
KG4sZSl9fTt2YXIgS3M9Imh0dHA6Ly93d3cudzMub3JnLzE5OTkveGh0bWwiLHRmPXtzdmc6Imh0
dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIix4aHRtbDpLcyx4bGluazoiaHR0cDovL3d3dy53My5v
cmcvMTk5OS94bGluayIseG1sOiJodHRwOi8vd3d3LnczLm9yZy9YTUwvMTk5OC9uYW1lc3BhY2Ui
LHhtbG5zOiJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3htbG5zLyJ9LG5mPWZ1bmN0aW9uKHQpe3Jl
dHVybiBmdW5jdGlvbigpe3JldHVybiB0aGlzLm1hdGNoZXModCl9fTtpZigidW5kZWZpbmVkIiE9
dHlwZW9mIGRvY3VtZW50KXt2YXIgZWY9ZG9jdW1lbnQuZG9jdW1lbnRFbGVtZW50O2lmKCFlZi5t
YXRjaGVzKXt2YXIgcmY9ZWYud2Via2l0TWF0Y2hlc1NlbGVjdG9yfHxlZi5tc01hdGNoZXNTZWxl
Y3Rvcnx8ZWYubW96TWF0Y2hlc1NlbGVjdG9yfHxlZi5vTWF0Y2hlc1NlbGVjdG9yO25mPWZ1bmN0
aW9uKHQpe3JldHVybiBmdW5jdGlvbigpe3JldHVybiByZi5jYWxsKHRoaXMsdCl9fX19dmFyIG9m
PW5mO3EucHJvdG90eXBlPXtjb25zdHJ1Y3RvcjpxLGFwcGVuZENoaWxkOmZ1bmN0aW9uKHQpe3Jl
dHVybiB0aGlzLl9wYXJlbnQuaW5zZXJ0QmVmb3JlKHQsdGhpcy5fbmV4dCl9LGluc2VydEJlZm9y
ZTpmdW5jdGlvbih0LG4pe3JldHVybiB0aGlzLl9wYXJlbnQuaW5zZXJ0QmVmb3JlKHQsbil9LHF1
ZXJ5U2VsZWN0b3I6ZnVuY3Rpb24odCl7cmV0dXJuIHRoaXMuX3BhcmVudC5xdWVyeVNlbGVjdG9y
KHQpfSxxdWVyeVNlbGVjdG9yQWxsOmZ1bmN0aW9uKHQpe3JldHVybiB0aGlzLl9wYXJlbnQucXVl
cnlTZWxlY3RvckFsbCh0KX19O3ZhciB1Zj0iJCI7SC5wcm90b3R5cGU9e2FkZDpmdW5jdGlvbih0
KXt0aGlzLl9uYW1lcy5pbmRleE9mKHQpPDAmJih0aGlzLl9uYW1lcy5wdXNoKHQpLHRoaXMuX25v
ZGUuc2V0QXR0cmlidXRlKCJjbGFzcyIsdGhpcy5fbmFtZXMuam9pbigiICIpKSl9LHJlbW92ZTpm
dW5jdGlvbih0KXt2YXIgbj10aGlzLl9uYW1lcy5pbmRleE9mKHQpO24+PTAmJih0aGlzLl9uYW1l
cy5zcGxpY2UobiwxKSx0aGlzLl9ub2RlLnNldEF0dHJpYnV0ZSgiY2xhc3MiLHRoaXMuX25hbWVz
LmpvaW4oIiAiKSkpfSxjb250YWluczpmdW5jdGlvbih0KXtyZXR1cm4gdGhpcy5fbmFtZXMuaW5k
ZXhPZih0KT49MH19O3ZhciBhZj17fTtpZih0LmV2ZW50PW51bGwsInVuZGVmaW5lZCIhPXR5cGVv
ZiBkb2N1bWVudCl7Im9ubW91c2VlbnRlciJpbiBkb2N1bWVudC5kb2N1bWVudEVsZW1lbnR8fChh
Zj17bW91c2VlbnRlcjoibW91c2VvdmVyIixtb3VzZWxlYXZlOiJtb3VzZW91dCJ9KX12YXIgY2Y9
W251bGxdO3V0LnByb3RvdHlwZT1hdC5wcm90b3R5cGU9e2NvbnN0cnVjdG9yOnV0LHNlbGVjdDpm
dW5jdGlvbih0KXsiZnVuY3Rpb24iIT10eXBlb2YgdCYmKHQ9eih0KSk7Zm9yKHZhciBuPXRoaXMu
X2dyb3VwcyxlPW4ubGVuZ3RoLHI9bmV3IEFycmF5KGUpLGk9MDtpPGU7KytpKWZvcih2YXIgbyx1
LGE9bltpXSxjPWEubGVuZ3RoLHM9cltpXT1uZXcgQXJyYXkoYyksZj0wO2Y8YzsrK2YpKG89YVtm
XSkmJih1PXQuY2FsbChvLG8uX19kYXRhX18sZixhKSkmJigiX19kYXRhX18iaW4gbyYmKHUuX19k
YXRhX189by5fX2RhdGFfXyksc1tmXT11KTtyZXR1cm4gbmV3IHV0KHIsdGhpcy5fcGFyZW50cyl9
LHNlbGVjdEFsbDpmdW5jdGlvbih0KXsiZnVuY3Rpb24iIT10eXBlb2YgdCYmKHQ9Uih0KSk7Zm9y
KHZhciBuPXRoaXMuX2dyb3VwcyxlPW4ubGVuZ3RoLHI9W10saT1bXSxvPTA7bzxlOysrbylmb3Io
dmFyIHUsYT1uW29dLGM9YS5sZW5ndGgscz0wO3M8YzsrK3MpKHU9YVtzXSkmJihyLnB1c2godC5j
YWxsKHUsdS5fX2RhdGFfXyxzLGEpKSxpLnB1c2godSkpO3JldHVybiBuZXcgdXQocixpKX0sZmls
dGVyOmZ1bmN0aW9uKHQpeyJmdW5jdGlvbiIhPXR5cGVvZiB0JiYodD1vZih0KSk7Zm9yKHZhciBu
PXRoaXMuX2dyb3VwcyxlPW4ubGVuZ3RoLHI9bmV3IEFycmF5KGUpLGk9MDtpPGU7KytpKWZvcih2
YXIgbyx1PW5baV0sYT11Lmxlbmd0aCxjPXJbaV09W10scz0wO3M8YTsrK3MpKG89dVtzXSkmJnQu
Y2FsbChvLG8uX19kYXRhX18scyx1KSYmYy5wdXNoKG8pO3JldHVybiBuZXcgdXQocix0aGlzLl9w
YXJlbnRzKX0sZGF0YTpmdW5jdGlvbih0LG4pe2lmKCF0KXJldHVybiBwPW5ldyBBcnJheSh0aGlz
LnNpemUoKSkscz0tMSx0aGlzLmVhY2goZnVuY3Rpb24odCl7cFsrK3NdPXR9KSxwO3ZhciBlPW4/
VTpELHI9dGhpcy5fcGFyZW50cyxpPXRoaXMuX2dyb3VwczsiZnVuY3Rpb24iIT10eXBlb2YgdCYm
KHQ9ZnVuY3Rpb24odCl7cmV0dXJuIGZ1bmN0aW9uKCl7cmV0dXJuIHR9fSh0KSk7Zm9yKHZhciBv
PWkubGVuZ3RoLHU9bmV3IEFycmF5KG8pLGE9bmV3IEFycmF5KG8pLGM9bmV3IEFycmF5KG8pLHM9
MDtzPG87KytzKXt2YXIgZj1yW3NdLGw9aVtzXSxoPWwubGVuZ3RoLHA9dC5jYWxsKGYsZiYmZi5f
X2RhdGFfXyxzLHIpLGQ9cC5sZW5ndGgsdj1hW3NdPW5ldyBBcnJheShkKSxnPXVbc109bmV3IEFy
cmF5KGQpO2UoZixsLHYsZyxjW3NdPW5ldyBBcnJheShoKSxwLG4pO2Zvcih2YXIgXyx5LG09MCx4
PTA7bTxkOysrbSlpZihfPXZbbV0pe2ZvcihtPj14JiYoeD1tKzEpOyEoeT1nW3hdKSYmKyt4PGQ7
KTtfLl9uZXh0PXl8fG51bGx9fXJldHVybiB1PW5ldyB1dCh1LHIpLHUuX2VudGVyPWEsdS5fZXhp
dD1jLHV9LGVudGVyOmZ1bmN0aW9uKCl7cmV0dXJuIG5ldyB1dCh0aGlzLl9lbnRlcnx8dGhpcy5f
Z3JvdXBzLm1hcChMKSx0aGlzLl9wYXJlbnRzKX0sZXhpdDpmdW5jdGlvbigpe3JldHVybiBuZXcg
dXQodGhpcy5fZXhpdHx8dGhpcy5fZ3JvdXBzLm1hcChMKSx0aGlzLl9wYXJlbnRzKX0sbWVyZ2U6
ZnVuY3Rpb24odCl7Zm9yKHZhciBuPXRoaXMuX2dyb3VwcyxlPXQuX2dyb3VwcyxyPW4ubGVuZ3Ro
LGk9ZS5sZW5ndGgsbz1NYXRoLm1pbihyLGkpLHU9bmV3IEFycmF5KHIpLGE9MDthPG87KythKWZv
cih2YXIgYyxzPW5bYV0sZj1lW2FdLGw9cy5sZW5ndGgsaD11W2FdPW5ldyBBcnJheShsKSxwPTA7
cDxsOysrcCkoYz1zW3BdfHxmW3BdKSYmKGhbcF09Yyk7Zm9yKDthPHI7KythKXVbYV09blthXTty
ZXR1cm4gbmV3IHV0KHUsdGhpcy5fcGFyZW50cyl9LG9yZGVyOmZ1bmN0aW9uKCl7Zm9yKHZhciB0
PXRoaXMuX2dyb3VwcyxuPS0xLGU9dC5sZW5ndGg7KytuPGU7KWZvcih2YXIgcixpPXRbbl0sbz1p
Lmxlbmd0aC0xLHU9aVtvXTstLW8+PTA7KShyPWlbb10pJiYodSYmdSE9PXIubmV4dFNpYmxpbmcm
JnUucGFyZW50Tm9kZS5pbnNlcnRCZWZvcmUocix1KSx1PXIpO3JldHVybiB0aGlzfSxzb3J0OmZ1
bmN0aW9uKHQpe2Z1bmN0aW9uIG4obixlKXtyZXR1cm4gbiYmZT90KG4uX19kYXRhX18sZS5fX2Rh
dGFfXyk6IW4tIWV9dHx8KHQ9Tyk7Zm9yKHZhciBlPXRoaXMuX2dyb3VwcyxyPWUubGVuZ3RoLGk9
bmV3IEFycmF5KHIpLG89MDtvPHI7KytvKXtmb3IodmFyIHUsYT1lW29dLGM9YS5sZW5ndGgscz1p
W29dPW5ldyBBcnJheShjKSxmPTA7ZjxjOysrZikodT1hW2ZdKSYmKHNbZl09dSk7cy5zb3J0KG4p
fXJldHVybiBuZXcgdXQoaSx0aGlzLl9wYXJlbnRzKS5vcmRlcigpfSxjYWxsOmZ1bmN0aW9uKCl7
dmFyIHQ9YXJndW1lbnRzWzBdO3JldHVybiBhcmd1bWVudHNbMF09dGhpcyx0LmFwcGx5KG51bGws
YXJndW1lbnRzKSx0aGlzfSxub2RlczpmdW5jdGlvbigpe3ZhciB0PW5ldyBBcnJheSh0aGlzLnNp
emUoKSksbj0tMTtyZXR1cm4gdGhpcy5lYWNoKGZ1bmN0aW9uKCl7dFsrK25dPXRoaXN9KSx0fSxu
b2RlOmZ1bmN0aW9uKCl7Zm9yKHZhciB0PXRoaXMuX2dyb3VwcyxuPTAsZT10Lmxlbmd0aDtuPGU7
KytuKWZvcih2YXIgcj10W25dLGk9MCxvPXIubGVuZ3RoO2k8bzsrK2kpe3ZhciB1PXJbaV07aWYo
dSlyZXR1cm4gdX1yZXR1cm4gbnVsbH0sc2l6ZTpmdW5jdGlvbigpe3ZhciB0PTA7cmV0dXJuIHRo
aXMuZWFjaChmdW5jdGlvbigpeysrdH0pLHR9LGVtcHR5OmZ1bmN0aW9uKCl7cmV0dXJuIXRoaXMu
bm9kZSgpfSxlYWNoOmZ1bmN0aW9uKHQpe2Zvcih2YXIgbj10aGlzLl9ncm91cHMsZT0wLHI9bi5s
ZW5ndGg7ZTxyOysrZSlmb3IodmFyIGksbz1uW2VdLHU9MCxhPW8ubGVuZ3RoO3U8YTsrK3UpKGk9
b1t1XSkmJnQuY2FsbChpLGkuX19kYXRhX18sdSxvKTtyZXR1cm4gdGhpc30sYXR0cjpmdW5jdGlv
bih0LG4pe3ZhciBlPUUodCk7aWYoYXJndW1lbnRzLmxlbmd0aDwyKXt2YXIgcj10aGlzLm5vZGUo
KTtyZXR1cm4gZS5sb2NhbD9yLmdldEF0dHJpYnV0ZU5TKGUuc3BhY2UsZS5sb2NhbCk6ci5nZXRB
dHRyaWJ1dGUoZSl9cmV0dXJuIHRoaXMuZWFjaCgobnVsbD09bj9lLmxvY2FsP2Z1bmN0aW9uKHQp
e3JldHVybiBmdW5jdGlvbigpe3RoaXMucmVtb3ZlQXR0cmlidXRlTlModC5zcGFjZSx0LmxvY2Fs
KX19OmZ1bmN0aW9uKHQpe3JldHVybiBmdW5jdGlvbigpe3RoaXMucmVtb3ZlQXR0cmlidXRlKHQp
fX06ImZ1bmN0aW9uIj09dHlwZW9mIG4/ZS5sb2NhbD9mdW5jdGlvbih0LG4pe3JldHVybiBmdW5j
dGlvbigpe3ZhciBlPW4uYXBwbHkodGhpcyxhcmd1bWVudHMpO251bGw9PWU/dGhpcy5yZW1vdmVB
dHRyaWJ1dGVOUyh0LnNwYWNlLHQubG9jYWwpOnRoaXMuc2V0QXR0cmlidXRlTlModC5zcGFjZSx0
LmxvY2FsLGUpfX06ZnVuY3Rpb24odCxuKXtyZXR1cm4gZnVuY3Rpb24oKXt2YXIgZT1uLmFwcGx5
KHRoaXMsYXJndW1lbnRzKTtudWxsPT1lP3RoaXMucmVtb3ZlQXR0cmlidXRlKHQpOnRoaXMuc2V0
QXR0cmlidXRlKHQsZSl9fTplLmxvY2FsP2Z1bmN0aW9uKHQsbil7cmV0dXJuIGZ1bmN0aW9uKCl7
dGhpcy5zZXRBdHRyaWJ1dGVOUyh0LnNwYWNlLHQubG9jYWwsbil9fTpmdW5jdGlvbih0LG4pe3Jl
dHVybiBmdW5jdGlvbigpe3RoaXMuc2V0QXR0cmlidXRlKHQsbil9fSkoZSxuKSl9LHN0eWxlOmZ1
bmN0aW9uKHQsbixlKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD4xP3RoaXMuZWFjaCgobnVsbD09
bj9mdW5jdGlvbih0KXtyZXR1cm4gZnVuY3Rpb24oKXt0aGlzLnN0eWxlLnJlbW92ZVByb3BlcnR5
KHQpfX06ImZ1bmN0aW9uIj09dHlwZW9mIG4/ZnVuY3Rpb24odCxuLGUpe3JldHVybiBmdW5jdGlv
bigpe3ZhciByPW4uYXBwbHkodGhpcyxhcmd1bWVudHMpO251bGw9PXI/dGhpcy5zdHlsZS5yZW1v
dmVQcm9wZXJ0eSh0KTp0aGlzLnN0eWxlLnNldFByb3BlcnR5KHQscixlKX19OmZ1bmN0aW9uKHQs
bixlKXtyZXR1cm4gZnVuY3Rpb24oKXt0aGlzLnN0eWxlLnNldFByb3BlcnR5KHQsbixlKX19KSh0
LG4sbnVsbD09ZT8iIjplKSk6SSh0aGlzLm5vZGUoKSx0KX0scHJvcGVydHk6ZnVuY3Rpb24odCxu
KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD4xP3RoaXMuZWFjaCgobnVsbD09bj9mdW5jdGlvbih0
KXtyZXR1cm4gZnVuY3Rpb24oKXtkZWxldGUgdGhpc1t0XX19OiJmdW5jdGlvbiI9PXR5cGVvZiBu
P2Z1bmN0aW9uKHQsbil7cmV0dXJuIGZ1bmN0aW9uKCl7dmFyIGU9bi5hcHBseSh0aGlzLGFyZ3Vt
ZW50cyk7bnVsbD09ZT9kZWxldGUgdGhpc1t0XTp0aGlzW3RdPWV9fTpmdW5jdGlvbih0LG4pe3Jl
dHVybiBmdW5jdGlvbigpe3RoaXNbdF09bn19KSh0LG4pKTp0aGlzLm5vZGUoKVt0XX0sY2xhc3Nl
ZDpmdW5jdGlvbih0LG4pe3ZhciBlPVkodCsiIik7aWYoYXJndW1lbnRzLmxlbmd0aDwyKXtmb3Io
dmFyIHI9Qih0aGlzLm5vZGUoKSksaT0tMSxvPWUubGVuZ3RoOysraTxvOylpZighci5jb250YWlu
cyhlW2ldKSlyZXR1cm4hMTtyZXR1cm4hMH1yZXR1cm4gdGhpcy5lYWNoKCgiZnVuY3Rpb24iPT10
eXBlb2Ygbj9mdW5jdGlvbih0LG4pe3JldHVybiBmdW5jdGlvbigpeyhuLmFwcGx5KHRoaXMsYXJn
dW1lbnRzKT9qOlgpKHRoaXMsdCl9fTpuP2Z1bmN0aW9uKHQpe3JldHVybiBmdW5jdGlvbigpe2oo
dGhpcyx0KX19OmZ1bmN0aW9uKHQpe3JldHVybiBmdW5jdGlvbigpe1godGhpcyx0KX19KShlLG4p
KX0sdGV4dDpmdW5jdGlvbih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD90aGlzLmVhY2gobnVs
bD09dD9WOigiZnVuY3Rpb24iPT10eXBlb2YgdD9mdW5jdGlvbih0KXtyZXR1cm4gZnVuY3Rpb24o
KXt2YXIgbj10LmFwcGx5KHRoaXMsYXJndW1lbnRzKTt0aGlzLnRleHRDb250ZW50PW51bGw9PW4/
IiI6bn19OmZ1bmN0aW9uKHQpe3JldHVybiBmdW5jdGlvbigpe3RoaXMudGV4dENvbnRlbnQ9dH19
KSh0KSk6dGhpcy5ub2RlKCkudGV4dENvbnRlbnR9LGh0bWw6ZnVuY3Rpb24odCl7cmV0dXJuIGFy
Z3VtZW50cy5sZW5ndGg/dGhpcy5lYWNoKG51bGw9PXQ/JDooImZ1bmN0aW9uIj09dHlwZW9mIHQ/
ZnVuY3Rpb24odCl7cmV0dXJuIGZ1bmN0aW9uKCl7dmFyIG49dC5hcHBseSh0aGlzLGFyZ3VtZW50
cyk7dGhpcy5pbm5lckhUTUw9bnVsbD09bj8iIjpufX06ZnVuY3Rpb24odCl7cmV0dXJuIGZ1bmN0
aW9uKCl7dGhpcy5pbm5lckhUTUw9dH19KSh0KSk6dGhpcy5ub2RlKCkuaW5uZXJIVE1MfSxyYWlz
ZTpmdW5jdGlvbigpe3JldHVybiB0aGlzLmVhY2goVyl9LGxvd2VyOmZ1bmN0aW9uKCl7cmV0dXJu
IHRoaXMuZWFjaChaKX0sYXBwZW5kOmZ1bmN0aW9uKHQpe3ZhciBuPSJmdW5jdGlvbiI9PXR5cGVv
ZiB0P3Q6QSh0KTtyZXR1cm4gdGhpcy5zZWxlY3QoZnVuY3Rpb24oKXtyZXR1cm4gdGhpcy5hcHBl
bmRDaGlsZChuLmFwcGx5KHRoaXMsYXJndW1lbnRzKSl9KX0saW5zZXJ0OmZ1bmN0aW9uKHQsbil7
dmFyIGU9ImZ1bmN0aW9uIj09dHlwZW9mIHQ/dDpBKHQpLHI9bnVsbD09bj9HOiJmdW5jdGlvbiI9
PXR5cGVvZiBuP246eihuKTtyZXR1cm4gdGhpcy5zZWxlY3QoZnVuY3Rpb24oKXtyZXR1cm4gdGhp
cy5pbnNlcnRCZWZvcmUoZS5hcHBseSh0aGlzLGFyZ3VtZW50cyksci5hcHBseSh0aGlzLGFyZ3Vt
ZW50cyl8fG51bGwpfSl9LHJlbW92ZTpmdW5jdGlvbigpe3JldHVybiB0aGlzLmVhY2goUSl9LGNs
b25lOmZ1bmN0aW9uKHQpe3JldHVybiB0aGlzLnNlbGVjdCh0P0s6Sil9LGRhdHVtOmZ1bmN0aW9u
KHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoP3RoaXMucHJvcGVydHkoIl9fZGF0YV9fIix0KTp0
aGlzLm5vZGUoKS5fX2RhdGFfX30sb246ZnVuY3Rpb24odCxuLGUpe3ZhciByLGksbz1mdW5jdGlv
bih0KXtyZXR1cm4gdC50cmltKCkuc3BsaXQoL158XHMrLykubWFwKGZ1bmN0aW9uKHQpe3ZhciBu
PSIiLGU9dC5pbmRleE9mKCIuIik7cmV0dXJuIGU+PTAmJihuPXQuc2xpY2UoZSsxKSx0PXQuc2xp
Y2UoMCxlKSkse3R5cGU6dCxuYW1lOm59fSl9KHQrIiIpLHU9by5sZW5ndGg7aWYoIShhcmd1bWVu
dHMubGVuZ3RoPDIpKXtmb3IoYT1uP3J0OmV0LG51bGw9PWUmJihlPSExKSxyPTA7cjx1Oysrcil0
aGlzLmVhY2goYShvW3JdLG4sZSkpO3JldHVybiB0aGlzfXZhciBhPXRoaXMubm9kZSgpLl9fb247
aWYoYSlmb3IodmFyIGMscz0wLGY9YS5sZW5ndGg7czxmOysrcylmb3Iocj0wLGM9YVtzXTtyPHU7
KytyKWlmKChpPW9bcl0pLnR5cGU9PT1jLnR5cGUmJmkubmFtZT09PWMubmFtZSlyZXR1cm4gYy52
YWx1ZX0sZGlzcGF0Y2g6ZnVuY3Rpb24odCxuKXtyZXR1cm4gdGhpcy5lYWNoKCgiZnVuY3Rpb24i
PT10eXBlb2Ygbj9mdW5jdGlvbih0LG4pe3JldHVybiBmdW5jdGlvbigpe3JldHVybiBvdCh0aGlz
LHQsbi5hcHBseSh0aGlzLGFyZ3VtZW50cykpfX06ZnVuY3Rpb24odCxuKXtyZXR1cm4gZnVuY3Rp
b24oKXtyZXR1cm4gb3QodGhpcyx0LG4pfX0pKHQsbikpfX07dmFyIHNmPTA7ZnQucHJvdG90eXBl
PXN0LnByb3RvdHlwZT17Y29uc3RydWN0b3I6ZnQsZ2V0OmZ1bmN0aW9uKHQpe2Zvcih2YXIgbj10
aGlzLl87IShuIGluIHQpOylpZighKHQ9dC5wYXJlbnROb2RlKSlyZXR1cm47cmV0dXJuIHRbbl19
LHNldDpmdW5jdGlvbih0LG4pe3JldHVybiB0W3RoaXMuX109bn0scmVtb3ZlOmZ1bmN0aW9uKHQp
e3JldHVybiB0aGlzLl8gaW4gdCYmZGVsZXRlIHRbdGhpcy5fXX0sdG9TdHJpbmc6ZnVuY3Rpb24o
KXtyZXR1cm4gdGhpcy5ffX0seHQucHJvdG90eXBlLm9uPWZ1bmN0aW9uKCl7dmFyIHQ9dGhpcy5f
Lm9uLmFwcGx5KHRoaXMuXyxhcmd1bWVudHMpO3JldHVybiB0PT09dGhpcy5fP3RoaXM6dH07dmFy
IGZmPSJcXHMqKFsrLV0/XFxkKylcXHMqIixsZj0iXFxzKihbKy1dP1xcZCpcXC4/XFxkKyg/Oltl
RV1bKy1dP1xcZCspPylcXHMqIixoZj0iXFxzKihbKy1dP1xcZCpcXC4/XFxkKyg/OltlRV1bKy1d
P1xcZCspPyklXFxzKiIscGY9L14jKFswLTlhLWZdezN9KSQvLGRmPS9eIyhbMC05YS1mXXs2fSkk
Lyx2Zj1uZXcgUmVnRXhwKCJecmdiXFwoIitbZmYsZmYsZmZdKyJcXCkkIiksZ2Y9bmV3IFJlZ0V4
cCgiXnJnYlxcKCIrW2hmLGhmLGhmXSsiXFwpJCIpLF9mPW5ldyBSZWdFeHAoIl5yZ2JhXFwoIitb
ZmYsZmYsZmYsbGZdKyJcXCkkIikseWY9bmV3IFJlZ0V4cCgiXnJnYmFcXCgiK1toZixoZixoZixs
Zl0rIlxcKSQiKSxtZj1uZXcgUmVnRXhwKCJeaHNsXFwoIitbbGYsaGYsaGZdKyJcXCkkIikseGY9
bmV3IFJlZ0V4cCgiXmhzbGFcXCgiK1tsZixoZixoZixsZl0rIlxcKSQiKSxiZj17YWxpY2VibHVl
OjE1NzkyMzgzLGFudGlxdWV3aGl0ZToxNjQ0NDM3NSxhcXVhOjY1NTM1LGFxdWFtYXJpbmU6ODM4
ODU2NCxhenVyZToxNTc5NDE3NSxiZWlnZToxNjExOTI2MCxiaXNxdWU6MTY3NzAyNDQsYmxhY2s6
MCxibGFuY2hlZGFsbW9uZDoxNjc3MjA0NSxibHVlOjI1NSxibHVldmlvbGV0OjkwNTUyMDIsYnJv
d246MTA4MjQyMzQsYnVybHl3b29kOjE0NTk2MjMxLGNhZGV0Ymx1ZTo2MjY2NTI4LGNoYXJ0cmV1
c2U6ODM4ODM1MixjaG9jb2xhdGU6MTM3ODk0NzAsY29yYWw6MTY3NDQyNzIsY29ybmZsb3dlcmJs
dWU6NjU5MTk4MSxjb3Juc2lsazoxNjc3NTM4OCxjcmltc29uOjE0NDIzMTAwLGN5YW46NjU1MzUs
ZGFya2JsdWU6MTM5LGRhcmtjeWFuOjM1NzIzLGRhcmtnb2xkZW5yb2Q6MTIwOTI5MzksZGFya2dy
YXk6MTExMTkwMTcsZGFya2dyZWVuOjI1NjAwLGRhcmtncmV5OjExMTE5MDE3LGRhcmtraGFraTox
MjQzMzI1OSxkYXJrbWFnZW50YTo5MTA5NjQzLGRhcmtvbGl2ZWdyZWVuOjU1OTc5OTksZGFya29y
YW5nZToxNjc0NzUyMCxkYXJrb3JjaGlkOjEwMDQwMDEyLGRhcmtyZWQ6OTEwOTUwNCxkYXJrc2Fs
bW9uOjE1MzA4NDEwLGRhcmtzZWFncmVlbjo5NDE5OTE5LGRhcmtzbGF0ZWJsdWU6NDczNDM0Nyxk
YXJrc2xhdGVncmF5OjMxMDA0OTUsZGFya3NsYXRlZ3JleTozMTAwNDk1LGRhcmt0dXJxdW9pc2U6
NTI5NDUsZGFya3Zpb2xldDo5Njk5NTM5LGRlZXBwaW5rOjE2NzE2OTQ3LGRlZXBza3libHVlOjQ5
MTUxLGRpbWdyYXk6NjkwODI2NSxkaW1ncmV5OjY5MDgyNjUsZG9kZ2VyYmx1ZToyMDAzMTk5LGZp
cmVicmljazoxMTY3NDE0NixmbG9yYWx3aGl0ZToxNjc3NTkyMCxmb3Jlc3RncmVlbjoyMjYzODQy
LGZ1Y2hzaWE6MTY3MTE5MzUsZ2FpbnNib3JvOjE0NDc0NDYwLGdob3N0d2hpdGU6MTYzMTY2NzEs
Z29sZDoxNjc2NjcyMCxnb2xkZW5yb2Q6MTQzMjkxMjAsZ3JheTo4NDIxNTA0LGdyZWVuOjMyNzY4
LGdyZWVueWVsbG93OjExNDAzMDU1LGdyZXk6ODQyMTUwNCxob25leWRldzoxNTc5NDE2MCxob3Rw
aW5rOjE2NzM4NzQwLGluZGlhbnJlZDoxMzQ1ODUyNCxpbmRpZ286NDkxNTMzMCxpdm9yeToxNjc3
NzIwMCxraGFraToxNTc4NzY2MCxsYXZlbmRlcjoxNTEzMjQxMCxsYXZlbmRlcmJsdXNoOjE2Nzcz
MzY1LGxhd25ncmVlbjo4MTkwOTc2LGxlbW9uY2hpZmZvbjoxNjc3NTg4NSxsaWdodGJsdWU6MTEz
OTMyNTQsbGlnaHRjb3JhbDoxNTc2MTUzNixsaWdodGN5YW46MTQ3NDU1OTksbGlnaHRnb2xkZW5y
b2R5ZWxsb3c6MTY0NDgyMTAsbGlnaHRncmF5OjEzODgyMzIzLGxpZ2h0Z3JlZW46OTQ5ODI1Nixs
aWdodGdyZXk6MTM4ODIzMjMsbGlnaHRwaW5rOjE2NzU4NDY1LGxpZ2h0c2FsbW9uOjE2NzUyNzYy
LGxpZ2h0c2VhZ3JlZW46MjE0Mjg5MCxsaWdodHNreWJsdWU6ODkwMDM0NixsaWdodHNsYXRlZ3Jh
eTo3ODMzNzUzLGxpZ2h0c2xhdGVncmV5Ojc4MzM3NTMsbGlnaHRzdGVlbGJsdWU6MTE1ODQ3MzQs
bGlnaHR5ZWxsb3c6MTY3NzcxODQsbGltZTo2NTI4MCxsaW1lZ3JlZW46MzMyOTMzMCxsaW5lbjox
NjQ0NTY3MCxtYWdlbnRhOjE2NzExOTM1LG1hcm9vbjo4Mzg4NjA4LG1lZGl1bWFxdWFtYXJpbmU6
NjczNzMyMixtZWRpdW1ibHVlOjIwNSxtZWRpdW1vcmNoaWQ6MTIyMTE2NjcsbWVkaXVtcHVycGxl
Ojk2NjI2ODMsbWVkaXVtc2VhZ3JlZW46Mzk3ODA5NyxtZWRpdW1zbGF0ZWJsdWU6ODA4Nzc5MCxt
ZWRpdW1zcHJpbmdncmVlbjo2NDE1NCxtZWRpdW10dXJxdW9pc2U6NDc3MjMwMCxtZWRpdW12aW9s
ZXRyZWQ6MTMwNDcxNzMsbWlkbmlnaHRibHVlOjE2NDQ5MTIsbWludGNyZWFtOjE2MTIxODUwLG1p
c3R5cm9zZToxNjc3MDI3Myxtb2NjYXNpbjoxNjc3MDIyOSxuYXZham93aGl0ZToxNjc2ODY4NSxu
YXZ5OjEyOCxvbGRsYWNlOjE2NjQzNTU4LG9saXZlOjg0MjEzNzYsb2xpdmVkcmFiOjcwNDg3Mzks
b3JhbmdlOjE2NzUzOTIwLG9yYW5nZXJlZDoxNjcyOTM0NCxvcmNoaWQ6MTQzMTU3MzQscGFsZWdv
bGRlbnJvZDoxNTY1NzEzMCxwYWxlZ3JlZW46MTAwMjU4ODAscGFsZXR1cnF1b2lzZToxMTUyOTk2
NixwYWxldmlvbGV0cmVkOjE0MzgxMjAzLHBhcGF5YXdoaXA6MTY3NzMwNzcscGVhY2hwdWZmOjE2
NzY3NjczLHBlcnU6MTM0Njg5OTEscGluazoxNjc2MTAzNSxwbHVtOjE0NTI0NjM3LHBvd2RlcmJs
dWU6MTE1OTE5MTAscHVycGxlOjgzODg3MzYscmViZWNjYXB1cnBsZTo2Njk3ODgxLHJlZDoxNjcx
MTY4MCxyb3N5YnJvd246MTIzNTc1MTkscm95YWxibHVlOjQyODY5NDUsc2FkZGxlYnJvd246OTEy
NzE4NyxzYWxtb246MTY0MTY4ODIsc2FuZHlicm93bjoxNjAzMjg2NCxzZWFncmVlbjozMDUwMzI3
LHNlYXNoZWxsOjE2Nzc0NjM4LHNpZW5uYToxMDUwNjc5NyxzaWx2ZXI6MTI2MzIyNTYsc2t5Ymx1
ZTo4OTAwMzMxLHNsYXRlYmx1ZTo2OTcwMDYxLHNsYXRlZ3JheTo3MzcyOTQ0LHNsYXRlZ3JleTo3
MzcyOTQ0LHNub3c6MTY3NzU5MzAsc3ByaW5nZ3JlZW46NjU0MDcsc3RlZWxibHVlOjQ2MjA5ODAs
dGFuOjEzODA4NzgwLHRlYWw6MzI4OTYsdGhpc3RsZToxNDIwNDg4OCx0b21hdG86MTY3MzcwOTUs
dHVycXVvaXNlOjQyNTE4NTYsdmlvbGV0OjE1NjMxMDg2LHdoZWF0OjE2MTEzMzMxLHdoaXRlOjE2
Nzc3MjE1LHdoaXRlc21va2U6MTYxMTkyODUseWVsbG93OjE2Nzc2OTYwLHllbGxvd2dyZWVuOjEw
MTQ1MDc0fTtOdChTdCxFdCx7ZGlzcGxheWFibGU6ZnVuY3Rpb24oKXtyZXR1cm4gdGhpcy5yZ2Io
KS5kaXNwbGF5YWJsZSgpfSx0b1N0cmluZzpmdW5jdGlvbigpe3JldHVybiB0aGlzLnJnYigpKyIi
fX0pLE50KFJ0LFB0LGt0KFN0LHticmlnaHRlcjpmdW5jdGlvbih0KXtyZXR1cm4gdD1udWxsPT10
PzEvLjc6TWF0aC5wb3coMS8uNyx0KSxuZXcgUnQodGhpcy5yKnQsdGhpcy5nKnQsdGhpcy5iKnQs
dGhpcy5vcGFjaXR5KX0sZGFya2VyOmZ1bmN0aW9uKHQpe3JldHVybiB0PW51bGw9PXQ/Ljc6TWF0
aC5wb3coLjcsdCksbmV3IFJ0KHRoaXMucip0LHRoaXMuZyp0LHRoaXMuYip0LHRoaXMub3BhY2l0
eSl9LHJnYjpmdW5jdGlvbigpe3JldHVybiB0aGlzfSxkaXNwbGF5YWJsZTpmdW5jdGlvbigpe3Jl
dHVybiAwPD10aGlzLnImJnRoaXMucjw9MjU1JiYwPD10aGlzLmcmJnRoaXMuZzw9MjU1JiYwPD10
aGlzLmImJnRoaXMuYjw9MjU1JiYwPD10aGlzLm9wYWNpdHkmJnRoaXMub3BhY2l0eTw9MX0sdG9T
dHJpbmc6ZnVuY3Rpb24oKXt2YXIgdD10aGlzLm9wYWNpdHk7cmV0dXJuKDE9PT0odD1pc05hTih0
KT8xOk1hdGgubWF4KDAsTWF0aC5taW4oMSx0KSkpPyJyZ2IoIjoicmdiYSgiKStNYXRoLm1heCgw
LE1hdGgubWluKDI1NSxNYXRoLnJvdW5kKHRoaXMucil8fDApKSsiLCAiK01hdGgubWF4KDAsTWF0
aC5taW4oMjU1LE1hdGgucm91bmQodGhpcy5nKXx8MCkpKyIsICIrTWF0aC5tYXgoMCxNYXRoLm1p
bigyNTUsTWF0aC5yb3VuZCh0aGlzLmIpfHwwKSkrKDE9PT10PyIpIjoiLCAiK3QrIikiKX19KSks
TnQoRHQscXQsa3QoU3Qse2JyaWdodGVyOmZ1bmN0aW9uKHQpe3JldHVybiB0PW51bGw9PXQ/MS8u
NzpNYXRoLnBvdygxLy43LHQpLG5ldyBEdCh0aGlzLmgsdGhpcy5zLHRoaXMubCp0LHRoaXMub3Bh
Y2l0eSl9LGRhcmtlcjpmdW5jdGlvbih0KXtyZXR1cm4gdD1udWxsPT10Py43Ok1hdGgucG93KC43
LHQpLG5ldyBEdCh0aGlzLmgsdGhpcy5zLHRoaXMubCp0LHRoaXMub3BhY2l0eSl9LHJnYjpmdW5j
dGlvbigpe3ZhciB0PXRoaXMuaCUzNjArMzYwKih0aGlzLmg8MCksbj1pc05hTih0KXx8aXNOYU4o
dGhpcy5zKT8wOnRoaXMucyxlPXRoaXMubCxyPWUrKGU8LjU/ZToxLWUpKm4saT0yKmUtcjtyZXR1
cm4gbmV3IFJ0KFV0KHQ+PTI0MD90LTI0MDp0KzEyMCxpLHIpLFV0KHQsaSxyKSxVdCh0PDEyMD90
KzI0MDp0LTEyMCxpLHIpLHRoaXMub3BhY2l0eSl9LGRpc3BsYXlhYmxlOmZ1bmN0aW9uKCl7cmV0
dXJuKDA8PXRoaXMucyYmdGhpcy5zPD0xfHxpc05hTih0aGlzLnMpKSYmMDw9dGhpcy5sJiZ0aGlz
Lmw8PTEmJjA8PXRoaXMub3BhY2l0eSYmdGhpcy5vcGFjaXR5PD0xfX0pKTt2YXIgd2Y9TWF0aC5Q
SS8xODAsTWY9MTgwL01hdGguUEksVGY9Ljk1MDQ3LE5mPTEsa2Y9MS4wODg4MyxTZj00LzI5LEVm
PTYvMjksQWY9MypFZipFZixDZj1FZipFZipFZjtOdChJdCxGdCxrdChTdCx7YnJpZ2h0ZXI6ZnVu
Y3Rpb24odCl7cmV0dXJuIG5ldyBJdCh0aGlzLmwrMTgqKG51bGw9PXQ/MTp0KSx0aGlzLmEsdGhp
cy5iLHRoaXMub3BhY2l0eSl9LGRhcmtlcjpmdW5jdGlvbih0KXtyZXR1cm4gbmV3IEl0KHRoaXMu
bC0xOCoobnVsbD09dD8xOnQpLHRoaXMuYSx0aGlzLmIsdGhpcy5vcGFjaXR5KX0scmdiOmZ1bmN0
aW9uKCl7dmFyIHQ9KHRoaXMubCsxNikvMTE2LG49aXNOYU4odGhpcy5hKT90OnQrdGhpcy5hLzUw
MCxlPWlzTmFOKHRoaXMuYik/dDp0LXRoaXMuYi8yMDA7cmV0dXJuIHQ9TmYqQnQodCksbj1UZipC
dChuKSxlPWtmKkJ0KGUpLG5ldyBSdChIdCgzLjI0MDQ1NDIqbi0xLjUzNzEzODUqdC0uNDk4NTMx
NCplKSxIdCgtLjk2OTI2NipuKzEuODc2MDEwOCp0Ky4wNDE1NTYqZSksSHQoLjA1NTY0MzQqbi0u
MjA0MDI1OSp0KzEuMDU3MjI1MiplKSx0aGlzLm9wYWNpdHkpfX0pKSxOdChWdCxYdCxrdChTdCx7
YnJpZ2h0ZXI6ZnVuY3Rpb24odCl7cmV0dXJuIG5ldyBWdCh0aGlzLmgsdGhpcy5jLHRoaXMubCsx
OCoobnVsbD09dD8xOnQpLHRoaXMub3BhY2l0eSl9LGRhcmtlcjpmdW5jdGlvbih0KXtyZXR1cm4g
bmV3IFZ0KHRoaXMuaCx0aGlzLmMsdGhpcy5sLTE4KihudWxsPT10PzE6dCksdGhpcy5vcGFjaXR5
KX0scmdiOmZ1bmN0aW9uKCl7cmV0dXJuIE90KHRoaXMpLnJnYigpfX0pKTt2YXIgemY9LS4yOTIy
NyxQZj0tLjkwNjQ5LFJmPTEuOTcyOTQsTGY9UmYqUGYscWY9MS43ODI3NypSZixEZj0xLjc4Mjc3
KnpmLSAtLjE0ODYxKlBmO050KFd0LCR0LGt0KFN0LHticmlnaHRlcjpmdW5jdGlvbih0KXtyZXR1
cm4gdD1udWxsPT10PzEvLjc6TWF0aC5wb3coMS8uNyx0KSxuZXcgV3QodGhpcy5oLHRoaXMucyx0
aGlzLmwqdCx0aGlzLm9wYWNpdHkpfSxkYXJrZXI6ZnVuY3Rpb24odCl7cmV0dXJuIHQ9bnVsbD09
dD8uNzpNYXRoLnBvdyguNyx0KSxuZXcgV3QodGhpcy5oLHRoaXMucyx0aGlzLmwqdCx0aGlzLm9w
YWNpdHkpfSxyZ2I6ZnVuY3Rpb24oKXt2YXIgdD1pc05hTih0aGlzLmgpPzA6KHRoaXMuaCsxMjAp
KndmLG49K3RoaXMubCxlPWlzTmFOKHRoaXMucyk/MDp0aGlzLnMqbiooMS1uKSxyPU1hdGguY29z
KHQpLGk9TWF0aC5zaW4odCk7cmV0dXJuIG5ldyBSdCgyNTUqKG4rZSooLS4xNDg2MSpyKzEuNzgy
NzcqaSkpLDI1NSoobitlKih6ZipyK1BmKmkpKSwyNTUqKG4rZSooUmYqcikpLHRoaXMub3BhY2l0
eSl9fSkpO3ZhciBVZixPZixGZixJZixZZixCZixIZj1mdW5jdGlvbiB0KG4pe2Z1bmN0aW9uIGUo
dCxuKXt2YXIgZT1yKCh0PVB0KHQpKS5yLChuPVB0KG4pKS5yKSxpPXIodC5nLG4uZyksbz1yKHQu
YixuLmIpLHU9ZW4odC5vcGFjaXR5LG4ub3BhY2l0eSk7cmV0dXJuIGZ1bmN0aW9uKG4pe3JldHVy
biB0LnI9ZShuKSx0Lmc9aShuKSx0LmI9byhuKSx0Lm9wYWNpdHk9dShuKSx0KyIifX12YXIgcj1u
bihuKTtyZXR1cm4gZS5nYW1tYT10LGV9KDEpLGpmPXJuKEd0KSxYZj1ybihRdCksVmY9L1stK10/
KD86XGQrXC4/XGQqfFwuP1xkKykoPzpbZUVdWy0rXT9cZCspPy9nLCRmPW5ldyBSZWdFeHAoVmYu
c291cmNlLCJnIiksV2Y9MTgwL01hdGguUEksWmY9e3RyYW5zbGF0ZVg6MCx0cmFuc2xhdGVZOjAs
cm90YXRlOjAsc2tld1g6MCxzY2FsZVg6MSxzY2FsZVk6MX0sR2Y9cG4oZnVuY3Rpb24odCl7cmV0
dXJuIm5vbmUiPT09dD9aZjooVWZ8fChVZj1kb2N1bWVudC5jcmVhdGVFbGVtZW50KCJESVYiKSxP
Zj1kb2N1bWVudC5kb2N1bWVudEVsZW1lbnQsRmY9ZG9jdW1lbnQuZGVmYXVsdFZpZXcpLFVmLnN0
eWxlLnRyYW5zZm9ybT10LHQ9RmYuZ2V0Q29tcHV0ZWRTdHlsZShPZi5hcHBlbmRDaGlsZChVZiks
bnVsbCkuZ2V0UHJvcGVydHlWYWx1ZSgidHJhbnNmb3JtIiksT2YucmVtb3ZlQ2hpbGQoVWYpLHQ9
dC5zbGljZSg3LC0xKS5zcGxpdCgiLCIpLGhuKCt0WzBdLCt0WzFdLCt0WzJdLCt0WzNdLCt0WzRd
LCt0WzVdKSl9LCJweCwgIiwicHgpIiwiZGVnKSIpLFFmPXBuKGZ1bmN0aW9uKHQpe3JldHVybiBu
dWxsPT10P1pmOihJZnx8KElmPWRvY3VtZW50LmNyZWF0ZUVsZW1lbnROUygiaHR0cDovL3d3dy53
My5vcmcvMjAwMC9zdmciLCJnIikpLElmLnNldEF0dHJpYnV0ZSgidHJhbnNmb3JtIix0KSwodD1J
Zi50cmFuc2Zvcm0uYmFzZVZhbC5jb25zb2xpZGF0ZSgpKT8odD10Lm1hdHJpeCxobih0LmEsdC5i
LHQuYyx0LmQsdC5lLHQuZikpOlpmKX0sIiwgIiwiKSIsIikiKSxKZj1NYXRoLlNRUlQyLEtmPTIs
dGw9NCxubD0xZS0xMixlbD1nbih0bikscmw9Z24oZW4pLGlsPV9uKHRuKSxvbD1fbihlbiksdWw9
eW4odG4pLGFsPXluKGVuKSxjbD0wLHNsPTAsZmw9MCxsbD0xZTMsaGw9MCxwbD0wLGRsPTAsdmw9
Im9iamVjdCI9PXR5cGVvZiBwZXJmb3JtYW5jZSYmcGVyZm9ybWFuY2Uubm93P3BlcmZvcm1hbmNl
OkRhdGUsZ2w9Im9iamVjdCI9PXR5cGVvZiB3aW5kb3cmJndpbmRvdy5yZXF1ZXN0QW5pbWF0aW9u
RnJhbWU/d2luZG93LnJlcXVlc3RBbmltYXRpb25GcmFtZS5iaW5kKHdpbmRvdyk6ZnVuY3Rpb24o
dCl7c2V0VGltZW91dCh0LDE3KX07Ym4ucHJvdG90eXBlPXduLnByb3RvdHlwZT17Y29uc3RydWN0
b3I6Ym4scmVzdGFydDpmdW5jdGlvbih0LG4sZSl7aWYoImZ1bmN0aW9uIiE9dHlwZW9mIHQpdGhy
b3cgbmV3IFR5cGVFcnJvcigiY2FsbGJhY2sgaXMgbm90IGEgZnVuY3Rpb24iKTtlPShudWxsPT1l
P21uKCk6K2UpKyhudWxsPT1uPzA6K24pLHRoaXMuX25leHR8fEJmPT09dGhpc3x8KEJmP0JmLl9u
ZXh0PXRoaXM6WWY9dGhpcyxCZj10aGlzKSx0aGlzLl9jYWxsPXQsdGhpcy5fdGltZT1lLGtuKCl9
LHN0b3A6ZnVuY3Rpb24oKXt0aGlzLl9jYWxsJiYodGhpcy5fY2FsbD1udWxsLHRoaXMuX3RpbWU9
MS8wLGtuKCkpfX07dmFyIF9sPU4oInN0YXJ0IiwiZW5kIiwiaW50ZXJydXB0IikseWw9W10sbWw9
MCx4bD0xLGJsPTIsd2w9MyxNbD00LFRsPTUsTmw9NixrbD1hdC5wcm90b3R5cGUuY29uc3RydWN0
b3IsU2w9MCxFbD1hdC5wcm90b3R5cGU7cW4ucHJvdG90eXBlPURuLnByb3RvdHlwZT17Y29uc3Ry
dWN0b3I6cW4sc2VsZWN0OmZ1bmN0aW9uKHQpe3ZhciBuPXRoaXMuX25hbWUsZT10aGlzLl9pZDsi
ZnVuY3Rpb24iIT10eXBlb2YgdCYmKHQ9eih0KSk7Zm9yKHZhciByPXRoaXMuX2dyb3VwcyxpPXIu
bGVuZ3RoLG89bmV3IEFycmF5KGkpLHU9MDt1PGk7Kyt1KWZvcih2YXIgYSxjLHM9clt1XSxmPXMu
bGVuZ3RoLGw9b1t1XT1uZXcgQXJyYXkoZiksaD0wO2g8ZjsrK2gpKGE9c1toXSkmJihjPXQuY2Fs
bChhLGEuX19kYXRhX18saCxzKSkmJigiX19kYXRhX18iaW4gYSYmKGMuX19kYXRhX189YS5fX2Rh
dGFfXyksbFtoXT1jLEVuKGxbaF0sbixlLGgsbCx6bihhLGUpKSk7cmV0dXJuIG5ldyBxbihvLHRo
aXMuX3BhcmVudHMsbixlKX0sc2VsZWN0QWxsOmZ1bmN0aW9uKHQpe3ZhciBuPXRoaXMuX25hbWUs
ZT10aGlzLl9pZDsiZnVuY3Rpb24iIT10eXBlb2YgdCYmKHQ9Uih0KSk7Zm9yKHZhciByPXRoaXMu
X2dyb3VwcyxpPXIubGVuZ3RoLG89W10sdT1bXSxhPTA7YTxpOysrYSlmb3IodmFyIGMscz1yW2Fd
LGY9cy5sZW5ndGgsbD0wO2w8ZjsrK2wpaWYoYz1zW2xdKXtmb3IodmFyIGgscD10LmNhbGwoYyxj
Ll9fZGF0YV9fLGwscyksZD16bihjLGUpLHY9MCxnPXAubGVuZ3RoO3Y8ZzsrK3YpKGg9cFt2XSkm
JkVuKGgsbixlLHYscCxkKTtvLnB1c2gocCksdS5wdXNoKGMpfXJldHVybiBuZXcgcW4obyx1LG4s
ZSl9LGZpbHRlcjpmdW5jdGlvbih0KXsiZnVuY3Rpb24iIT10eXBlb2YgdCYmKHQ9b2YodCkpO2Zv
cih2YXIgbj10aGlzLl9ncm91cHMsZT1uLmxlbmd0aCxyPW5ldyBBcnJheShlKSxpPTA7aTxlOysr
aSlmb3IodmFyIG8sdT1uW2ldLGE9dS5sZW5ndGgsYz1yW2ldPVtdLHM9MDtzPGE7KytzKShvPXVb
c10pJiZ0LmNhbGwobyxvLl9fZGF0YV9fLHMsdSkmJmMucHVzaChvKTtyZXR1cm4gbmV3IHFuKHIs
dGhpcy5fcGFyZW50cyx0aGlzLl9uYW1lLHRoaXMuX2lkKX0sbWVyZ2U6ZnVuY3Rpb24odCl7aWYo
dC5faWQhPT10aGlzLl9pZCl0aHJvdyBuZXcgRXJyb3I7Zm9yKHZhciBuPXRoaXMuX2dyb3Vwcyxl
PXQuX2dyb3VwcyxyPW4ubGVuZ3RoLGk9ZS5sZW5ndGgsbz1NYXRoLm1pbihyLGkpLHU9bmV3IEFy
cmF5KHIpLGE9MDthPG87KythKWZvcih2YXIgYyxzPW5bYV0sZj1lW2FdLGw9cy5sZW5ndGgsaD11
W2FdPW5ldyBBcnJheShsKSxwPTA7cDxsOysrcCkoYz1zW3BdfHxmW3BdKSYmKGhbcF09Yyk7Zm9y
KDthPHI7KythKXVbYV09blthXTtyZXR1cm4gbmV3IHFuKHUsdGhpcy5fcGFyZW50cyx0aGlzLl9u
YW1lLHRoaXMuX2lkKX0sc2VsZWN0aW9uOmZ1bmN0aW9uKCl7cmV0dXJuIG5ldyBrbCh0aGlzLl9n
cm91cHMsdGhpcy5fcGFyZW50cyl9LHRyYW5zaXRpb246ZnVuY3Rpb24oKXtmb3IodmFyIHQ9dGhp
cy5fbmFtZSxuPXRoaXMuX2lkLGU9VW4oKSxyPXRoaXMuX2dyb3VwcyxpPXIubGVuZ3RoLG89MDtv
PGk7KytvKWZvcih2YXIgdSxhPXJbb10sYz1hLmxlbmd0aCxzPTA7czxjOysrcylpZih1PWFbc10p
e3ZhciBmPXpuKHUsbik7RW4odSx0LGUscyxhLHt0aW1lOmYudGltZStmLmRlbGF5K2YuZHVyYXRp
b24sZGVsYXk6MCxkdXJhdGlvbjpmLmR1cmF0aW9uLGVhc2U6Zi5lYXNlfSl9cmV0dXJuIG5ldyBx
bihyLHRoaXMuX3BhcmVudHMsdCxlKX0sY2FsbDpFbC5jYWxsLG5vZGVzOkVsLm5vZGVzLG5vZGU6
RWwubm9kZSxzaXplOkVsLnNpemUsZW1wdHk6RWwuZW1wdHksZWFjaDpFbC5lYWNoLG9uOmZ1bmN0
aW9uKHQsbil7dmFyIGU9dGhpcy5faWQ7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg8Mj96bih0aGlz
Lm5vZGUoKSxlKS5vbi5vbih0KTp0aGlzLmVhY2goZnVuY3Rpb24odCxuLGUpe3ZhciByLGksbz1m
dW5jdGlvbih0KXtyZXR1cm4odCsiIikudHJpbSgpLnNwbGl0KC9efFxzKy8pLmV2ZXJ5KGZ1bmN0
aW9uKHQpe3ZhciBuPXQuaW5kZXhPZigiLiIpO3JldHVybiBuPj0wJiYodD10LnNsaWNlKDAsbikp
LCF0fHwic3RhcnQiPT09dH0pfShuKT9BbjpDbjtyZXR1cm4gZnVuY3Rpb24oKXt2YXIgdT1vKHRo
aXMsdCksYT11Lm9uO2EhPT1yJiYoaT0ocj1hKS5jb3B5KCkpLm9uKG4sZSksdS5vbj1pfX0oZSx0
LG4pKX0sYXR0cjpmdW5jdGlvbih0LG4pe3ZhciBlPUUodCkscj0idHJhbnNmb3JtIj09PWU/UWY6
TG47cmV0dXJuIHRoaXMuYXR0clR3ZWVuKHQsImZ1bmN0aW9uIj09dHlwZW9mIG4/KGUubG9jYWw/
ZnVuY3Rpb24odCxuLGUpe3ZhciByLGksbztyZXR1cm4gZnVuY3Rpb24oKXt2YXIgdSxhPWUodGhp
cyk7aWYobnVsbCE9YSlyZXR1cm4odT10aGlzLmdldEF0dHJpYnV0ZU5TKHQuc3BhY2UsdC5sb2Nh
bCkpPT09YT9udWxsOnU9PT1yJiZhPT09aT9vOm89bihyPXUsaT1hKTt0aGlzLnJlbW92ZUF0dHJp
YnV0ZU5TKHQuc3BhY2UsdC5sb2NhbCl9fTpmdW5jdGlvbih0LG4sZSl7dmFyIHIsaSxvO3JldHVy
biBmdW5jdGlvbigpe3ZhciB1LGE9ZSh0aGlzKTtpZihudWxsIT1hKXJldHVybih1PXRoaXMuZ2V0
QXR0cmlidXRlKHQpKT09PWE/bnVsbDp1PT09ciYmYT09PWk/bzpvPW4ocj11LGk9YSk7dGhpcy5y
ZW1vdmVBdHRyaWJ1dGUodCl9fSkoZSxyLFJuKHRoaXMsImF0dHIuIit0LG4pKTpudWxsPT1uPyhl
LmxvY2FsP2Z1bmN0aW9uKHQpe3JldHVybiBmdW5jdGlvbigpe3RoaXMucmVtb3ZlQXR0cmlidXRl
TlModC5zcGFjZSx0LmxvY2FsKX19OmZ1bmN0aW9uKHQpe3JldHVybiBmdW5jdGlvbigpe3RoaXMu
cmVtb3ZlQXR0cmlidXRlKHQpfX0pKGUpOihlLmxvY2FsP2Z1bmN0aW9uKHQsbixlKXt2YXIgcixp
O3JldHVybiBmdW5jdGlvbigpe3ZhciBvPXRoaXMuZ2V0QXR0cmlidXRlTlModC5zcGFjZSx0Lmxv
Y2FsKTtyZXR1cm4gbz09PWU/bnVsbDpvPT09cj9pOmk9bihyPW8sZSl9fTpmdW5jdGlvbih0LG4s
ZSl7dmFyIHIsaTtyZXR1cm4gZnVuY3Rpb24oKXt2YXIgbz10aGlzLmdldEF0dHJpYnV0ZSh0KTty
ZXR1cm4gbz09PWU/bnVsbDpvPT09cj9pOmk9bihyPW8sZSl9fSkoZSxyLG4rIiIpKX0sYXR0clR3
ZWVuOmZ1bmN0aW9uKHQsbil7dmFyIGU9ImF0dHIuIit0O2lmKGFyZ3VtZW50cy5sZW5ndGg8Mily
ZXR1cm4oZT10aGlzLnR3ZWVuKGUpKSYmZS5fdmFsdWU7aWYobnVsbD09bilyZXR1cm4gdGhpcy50
d2VlbihlLG51bGwpO2lmKCJmdW5jdGlvbiIhPXR5cGVvZiBuKXRocm93IG5ldyBFcnJvcjt2YXIg
cj1FKHQpO3JldHVybiB0aGlzLnR3ZWVuKGUsKHIubG9jYWw/ZnVuY3Rpb24odCxuKXtmdW5jdGlv
biBlKCl7dmFyIGU9dGhpcyxyPW4uYXBwbHkoZSxhcmd1bWVudHMpO3JldHVybiByJiZmdW5jdGlv
bihuKXtlLnNldEF0dHJpYnV0ZU5TKHQuc3BhY2UsdC5sb2NhbCxyKG4pKX19cmV0dXJuIGUuX3Zh
bHVlPW4sZX06ZnVuY3Rpb24odCxuKXtmdW5jdGlvbiBlKCl7dmFyIGU9dGhpcyxyPW4uYXBwbHko
ZSxhcmd1bWVudHMpO3JldHVybiByJiZmdW5jdGlvbihuKXtlLnNldEF0dHJpYnV0ZSh0LHIobikp
fX1yZXR1cm4gZS5fdmFsdWU9bixlfSkocixuKSl9LHN0eWxlOmZ1bmN0aW9uKHQsbixlKXt2YXIg
cj0idHJhbnNmb3JtIj09KHQrPSIiKT9HZjpMbjtyZXR1cm4gbnVsbD09bj90aGlzLnN0eWxlVHdl
ZW4odCxmdW5jdGlvbih0LG4pe3ZhciBlLHIsaTtyZXR1cm4gZnVuY3Rpb24oKXt2YXIgbz1JKHRo
aXMsdCksdT0odGhpcy5zdHlsZS5yZW1vdmVQcm9wZXJ0eSh0KSxJKHRoaXMsdCkpO3JldHVybiBv
PT09dT9udWxsOm89PT1lJiZ1PT09cj9pOmk9bihlPW8scj11KX19KHQscikpLm9uKCJlbmQuc3R5
bGUuIit0LGZ1bmN0aW9uKHQpe3JldHVybiBmdW5jdGlvbigpe3RoaXMuc3R5bGUucmVtb3ZlUHJv
cGVydHkodCl9fSh0KSk6dGhpcy5zdHlsZVR3ZWVuKHQsImZ1bmN0aW9uIj09dHlwZW9mIG4/ZnVu
Y3Rpb24odCxuLGUpe3ZhciByLGksbztyZXR1cm4gZnVuY3Rpb24oKXt2YXIgdT1JKHRoaXMsdCks
YT1lKHRoaXMpO3JldHVybiBudWxsPT1hJiYodGhpcy5zdHlsZS5yZW1vdmVQcm9wZXJ0eSh0KSxh
PUkodGhpcyx0KSksdT09PWE/bnVsbDp1PT09ciYmYT09PWk/bzpvPW4ocj11LGk9YSl9fSh0LHIs
Um4odGhpcywic3R5bGUuIit0LG4pKTpmdW5jdGlvbih0LG4sZSl7dmFyIHIsaTtyZXR1cm4gZnVu
Y3Rpb24oKXt2YXIgbz1JKHRoaXMsdCk7cmV0dXJuIG89PT1lP251bGw6bz09PXI/aTppPW4ocj1v
LGUpfX0odCxyLG4rIiIpLGUpfSxzdHlsZVR3ZWVuOmZ1bmN0aW9uKHQsbixlKXt2YXIgcj0ic3R5
bGUuIisodCs9IiIpO2lmKGFyZ3VtZW50cy5sZW5ndGg8MilyZXR1cm4ocj10aGlzLnR3ZWVuKHIp
KSYmci5fdmFsdWU7aWYobnVsbD09bilyZXR1cm4gdGhpcy50d2VlbihyLG51bGwpO2lmKCJmdW5j
dGlvbiIhPXR5cGVvZiBuKXRocm93IG5ldyBFcnJvcjtyZXR1cm4gdGhpcy50d2VlbihyLGZ1bmN0
aW9uKHQsbixlKXtmdW5jdGlvbiByKCl7dmFyIHI9dGhpcyxpPW4uYXBwbHkocixhcmd1bWVudHMp
O3JldHVybiBpJiZmdW5jdGlvbihuKXtyLnN0eWxlLnNldFByb3BlcnR5KHQsaShuKSxlKX19cmV0
dXJuIHIuX3ZhbHVlPW4scn0odCxuLG51bGw9PWU/IiI6ZSkpfSx0ZXh0OmZ1bmN0aW9uKHQpe3Jl
dHVybiB0aGlzLnR3ZWVuKCJ0ZXh0IiwiZnVuY3Rpb24iPT10eXBlb2YgdD9mdW5jdGlvbih0KXty
ZXR1cm4gZnVuY3Rpb24oKXt2YXIgbj10KHRoaXMpO3RoaXMudGV4dENvbnRlbnQ9bnVsbD09bj8i
IjpufX0oUm4odGhpcywidGV4dCIsdCkpOmZ1bmN0aW9uKHQpe3JldHVybiBmdW5jdGlvbigpe3Ro
aXMudGV4dENvbnRlbnQ9dH19KG51bGw9PXQ/IiI6dCsiIikpfSxyZW1vdmU6ZnVuY3Rpb24oKXty
ZXR1cm4gdGhpcy5vbigiZW5kLnJlbW92ZSIsZnVuY3Rpb24odCl7cmV0dXJuIGZ1bmN0aW9uKCl7
dmFyIG49dGhpcy5wYXJlbnROb2RlO2Zvcih2YXIgZSBpbiB0aGlzLl9fdHJhbnNpdGlvbilpZigr
ZSE9PXQpcmV0dXJuO24mJm4ucmVtb3ZlQ2hpbGQodGhpcyl9fSh0aGlzLl9pZCkpfSx0d2Vlbjpm
dW5jdGlvbih0LG4pe3ZhciBlPXRoaXMuX2lkO2lmKHQrPSIiLGFyZ3VtZW50cy5sZW5ndGg8Mil7
Zm9yKHZhciByLGk9em4odGhpcy5ub2RlKCksZSkudHdlZW4sbz0wLHU9aS5sZW5ndGg7bzx1Oysr
bylpZigocj1pW29dKS5uYW1lPT09dClyZXR1cm4gci52YWx1ZTtyZXR1cm4gbnVsbH1yZXR1cm4g
dGhpcy5lYWNoKChudWxsPT1uP2Z1bmN0aW9uKHQsbil7dmFyIGUscjtyZXR1cm4gZnVuY3Rpb24o
KXt2YXIgaT1Dbih0aGlzLHQpLG89aS50d2VlbjtpZihvIT09ZSlmb3IodmFyIHU9MCxhPShyPWU9
bykubGVuZ3RoO3U8YTsrK3UpaWYoclt1XS5uYW1lPT09bil7KHI9ci5zbGljZSgpKS5zcGxpY2Uo
dSwxKTticmVha31pLnR3ZWVuPXJ9fTpmdW5jdGlvbih0LG4sZSl7dmFyIHIsaTtpZigiZnVuY3Rp
b24iIT10eXBlb2YgZSl0aHJvdyBuZXcgRXJyb3I7cmV0dXJuIGZ1bmN0aW9uKCl7dmFyIG89Q24o
dGhpcyx0KSx1PW8udHdlZW47aWYodSE9PXIpe2k9KHI9dSkuc2xpY2UoKTtmb3IodmFyIGE9e25h
bWU6bix2YWx1ZTplfSxjPTAscz1pLmxlbmd0aDtjPHM7KytjKWlmKGlbY10ubmFtZT09PW4pe2lb
Y109YTticmVha31jPT09cyYmaS5wdXNoKGEpfW8udHdlZW49aX19KShlLHQsbikpfSxkZWxheTpm
dW5jdGlvbih0KXt2YXIgbj10aGlzLl9pZDtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD90aGlzLmVh
Y2goKCJmdW5jdGlvbiI9PXR5cGVvZiB0P2Z1bmN0aW9uKHQsbil7cmV0dXJuIGZ1bmN0aW9uKCl7
QW4odGhpcyx0KS5kZWxheT0rbi5hcHBseSh0aGlzLGFyZ3VtZW50cyl9fTpmdW5jdGlvbih0LG4p
e3JldHVybiBuPStuLGZ1bmN0aW9uKCl7QW4odGhpcyx0KS5kZWxheT1ufX0pKG4sdCkpOnpuKHRo
aXMubm9kZSgpLG4pLmRlbGF5fSxkdXJhdGlvbjpmdW5jdGlvbih0KXt2YXIgbj10aGlzLl9pZDty
ZXR1cm4gYXJndW1lbnRzLmxlbmd0aD90aGlzLmVhY2goKCJmdW5jdGlvbiI9PXR5cGVvZiB0P2Z1
bmN0aW9uKHQsbil7cmV0dXJuIGZ1bmN0aW9uKCl7Q24odGhpcyx0KS5kdXJhdGlvbj0rbi5hcHBs
eSh0aGlzLGFyZ3VtZW50cyl9fTpmdW5jdGlvbih0LG4pe3JldHVybiBuPStuLGZ1bmN0aW9uKCl7
Q24odGhpcyx0KS5kdXJhdGlvbj1ufX0pKG4sdCkpOnpuKHRoaXMubm9kZSgpLG4pLmR1cmF0aW9u
fSxlYXNlOmZ1bmN0aW9uKHQpe3ZhciBuPXRoaXMuX2lkO3JldHVybiBhcmd1bWVudHMubGVuZ3Ro
P3RoaXMuZWFjaChmdW5jdGlvbih0LG4pe2lmKCJmdW5jdGlvbiIhPXR5cGVvZiBuKXRocm93IG5l
dyBFcnJvcjtyZXR1cm4gZnVuY3Rpb24oKXtDbih0aGlzLHQpLmVhc2U9bn19KG4sdCkpOnpuKHRo
aXMubm9kZSgpLG4pLmVhc2V9fTt2YXIgQWw9ZnVuY3Rpb24gdChuKXtmdW5jdGlvbiBlKHQpe3Jl
dHVybiBNYXRoLnBvdyh0LG4pfXJldHVybiBuPStuLGUuZXhwb25lbnQ9dCxlfSgzKSxDbD1mdW5j
dGlvbiB0KG4pe2Z1bmN0aW9uIGUodCl7cmV0dXJuIDEtTWF0aC5wb3coMS10LG4pfXJldHVybiBu
PStuLGUuZXhwb25lbnQ9dCxlfSgzKSx6bD1mdW5jdGlvbiB0KG4pe2Z1bmN0aW9uIGUodCl7cmV0
dXJuKCh0Kj0yKTw9MT9NYXRoLnBvdyh0LG4pOjItTWF0aC5wb3coMi10LG4pKS8yfXJldHVybiBu
PStuLGUuZXhwb25lbnQ9dCxlfSgzKSxQbD1NYXRoLlBJLFJsPVBsLzIsTGw9NC8xMSxxbD02LzEx
LERsPTgvMTEsVWw9Ljc1LE9sPTkvMTEsRmw9MTAvMTEsSWw9LjkzNzUsWWw9MjEvMjIsQmw9NjMv
NjQsSGw9MS9MbC9MbCxqbD1mdW5jdGlvbiB0KG4pe2Z1bmN0aW9uIGUodCl7cmV0dXJuIHQqdCoo
KG4rMSkqdC1uKX1yZXR1cm4gbj0rbixlLm92ZXJzaG9vdD10LGV9KDEuNzAxNTgpLFhsPWZ1bmN0
aW9uIHQobil7ZnVuY3Rpb24gZSh0KXtyZXR1cm4tLXQqdCooKG4rMSkqdCtuKSsxfXJldHVybiBu
PStuLGUub3ZlcnNob290PXQsZX0oMS43MDE1OCksVmw9ZnVuY3Rpb24gdChuKXtmdW5jdGlvbiBl
KHQpe3JldHVybigodCo9Mik8MT90KnQqKChuKzEpKnQtbik6KHQtPTIpKnQqKChuKzEpKnQrbikr
MikvMn1yZXR1cm4gbj0rbixlLm92ZXJzaG9vdD10LGV9KDEuNzAxNTgpLCRsPTIqTWF0aC5QSSxX
bD1mdW5jdGlvbiB0KG4sZSl7ZnVuY3Rpb24gcih0KXtyZXR1cm4gbipNYXRoLnBvdygyLDEwKi0t
dCkqTWF0aC5zaW4oKGktdCkvZSl9dmFyIGk9TWF0aC5hc2luKDEvKG49TWF0aC5tYXgoMSxuKSkp
KihlLz0kbCk7cmV0dXJuIHIuYW1wbGl0dWRlPWZ1bmN0aW9uKG4pe3JldHVybiB0KG4sZSokbCl9
LHIucGVyaW9kPWZ1bmN0aW9uKGUpe3JldHVybiB0KG4sZSl9LHJ9KDEsLjMpLFpsPWZ1bmN0aW9u
IHQobixlKXtmdW5jdGlvbiByKHQpe3JldHVybiAxLW4qTWF0aC5wb3coMiwtMTAqKHQ9K3QpKSpN
YXRoLnNpbigodCtpKS9lKX12YXIgaT1NYXRoLmFzaW4oMS8obj1NYXRoLm1heCgxLG4pKSkqKGUv
PSRsKTtyZXR1cm4gci5hbXBsaXR1ZGU9ZnVuY3Rpb24obil7cmV0dXJuIHQobixlKiRsKX0sci5w
ZXJpb2Q9ZnVuY3Rpb24oZSl7cmV0dXJuIHQobixlKX0scn0oMSwuMyksR2w9ZnVuY3Rpb24gdChu
LGUpe2Z1bmN0aW9uIHIodCl7cmV0dXJuKCh0PTIqdC0xKTwwP24qTWF0aC5wb3coMiwxMCp0KSpN
YXRoLnNpbigoaS10KS9lKToyLW4qTWF0aC5wb3coMiwtMTAqdCkqTWF0aC5zaW4oKGkrdCkvZSkp
LzJ9dmFyIGk9TWF0aC5hc2luKDEvKG49TWF0aC5tYXgoMSxuKSkpKihlLz0kbCk7cmV0dXJuIHIu
YW1wbGl0dWRlPWZ1bmN0aW9uKG4pe3JldHVybiB0KG4sZSokbCl9LHIucGVyaW9kPWZ1bmN0aW9u
KGUpe3JldHVybiB0KG4sZSl9LHJ9KDEsLjMpLFFsPXt0aW1lOm51bGwsZGVsYXk6MCxkdXJhdGlv
bjoyNTAsZWFzZTpGbn07YXQucHJvdG90eXBlLmludGVycnVwdD1mdW5jdGlvbih0KXtyZXR1cm4g
dGhpcy5lYWNoKGZ1bmN0aW9uKCl7UG4odGhpcyx0KX0pfSxhdC5wcm90b3R5cGUudHJhbnNpdGlv
bj1mdW5jdGlvbih0KXt2YXIgbixlO3QgaW5zdGFuY2VvZiBxbj8obj10Ll9pZCx0PXQuX25hbWUp
OihuPVVuKCksKGU9UWwpLnRpbWU9bW4oKSx0PW51bGw9PXQ/bnVsbDp0KyIiKTtmb3IodmFyIHI9
dGhpcy5fZ3JvdXBzLGk9ci5sZW5ndGgsbz0wO288aTsrK28pZm9yKHZhciB1LGE9cltvXSxjPWEu
bGVuZ3RoLHM9MDtzPGM7KytzKSh1PWFbc10pJiZFbih1LHQsbixzLGEsZXx8am4odSxuKSk7cmV0
dXJuIG5ldyBxbihyLHRoaXMuX3BhcmVudHMsdCxuKX07dmFyIEpsPVtudWxsXSxLbD17bmFtZToi
ZHJhZyJ9LHRoPXtuYW1lOiJzcGFjZSJ9LG5oPXtuYW1lOiJoYW5kbGUifSxlaD17bmFtZToiY2Vu
dGVyIn0scmg9e25hbWU6IngiLGhhbmRsZXM6WyJlIiwidyJdLm1hcChXbiksaW5wdXQ6ZnVuY3Rp
b24odCxuKXtyZXR1cm4gdCYmW1t0WzBdLG5bMF1bMV1dLFt0WzFdLG5bMV1bMV1dXX0sb3V0cHV0
OmZ1bmN0aW9uKHQpe3JldHVybiB0JiZbdFswXVswXSx0WzFdWzBdXX19LGloPXtuYW1lOiJ5Iixo
YW5kbGVzOlsibiIsInMiXS5tYXAoV24pLGlucHV0OmZ1bmN0aW9uKHQsbil7cmV0dXJuIHQmJltb
blswXVswXSx0WzBdXSxbblsxXVswXSx0WzFdXV19LG91dHB1dDpmdW5jdGlvbih0KXtyZXR1cm4g
dCYmW3RbMF1bMV0sdFsxXVsxXV19fSxvaD17bmFtZToieHkiLGhhbmRsZXM6WyJuIiwiZSIsInMi
LCJ3IiwibnciLCJuZSIsInNlIiwic3ciXS5tYXAoV24pLGlucHV0OmZ1bmN0aW9uKHQpe3JldHVy
biB0fSxvdXRwdXQ6ZnVuY3Rpb24odCl7cmV0dXJuIHR9fSx1aD17b3ZlcmxheToiY3Jvc3NoYWly
IixzZWxlY3Rpb246Im1vdmUiLG46Im5zLXJlc2l6ZSIsZToiZXctcmVzaXplIixzOiJucy1yZXNp
emUiLHc6ImV3LXJlc2l6ZSIsbnc6Im53c2UtcmVzaXplIixuZToibmVzdy1yZXNpemUiLHNlOiJu
d3NlLXJlc2l6ZSIsc3c6Im5lc3ctcmVzaXplIn0sYWg9e2U6InciLHc6ImUiLG53OiJuZSIsbmU6
Im53IixzZToic3ciLHN3OiJzZSJ9LGNoPXtuOiJzIixzOiJuIixudzoic3ciLG5lOiJzZSIsc2U6
Im5lIixzdzoibncifSxzaD17b3ZlcmxheToxLHNlbGVjdGlvbjoxLG46bnVsbCxlOjEsczpudWxs
LHc6LTEsbnc6LTEsbmU6MSxzZToxLHN3Oi0xfSxmaD17b3ZlcmxheToxLHNlbGVjdGlvbjoxLG46
LTEsZTpudWxsLHM6MSx3Om51bGwsbnc6LTEsbmU6LTEsc2U6MSxzdzoxfSxsaD1NYXRoLmNvcyxo
aD1NYXRoLnNpbixwaD1NYXRoLlBJLGRoPXBoLzIsdmg9MipwaCxnaD1NYXRoLm1heCxfaD1BcnJh
eS5wcm90b3R5cGUuc2xpY2UseWg9TWF0aC5QSSxtaD0yKnloLHhoPW1oLTFlLTY7bmUucHJvdG90
eXBlPWVlLnByb3RvdHlwZT17Y29uc3RydWN0b3I6bmUsbW92ZVRvOmZ1bmN0aW9uKHQsbil7dGhp
cy5fKz0iTSIrKHRoaXMuX3gwPXRoaXMuX3gxPSt0KSsiLCIrKHRoaXMuX3kwPXRoaXMuX3kxPStu
KX0sY2xvc2VQYXRoOmZ1bmN0aW9uKCl7bnVsbCE9PXRoaXMuX3gxJiYodGhpcy5feDE9dGhpcy5f
eDAsdGhpcy5feTE9dGhpcy5feTAsdGhpcy5fKz0iWiIpfSxsaW5lVG86ZnVuY3Rpb24odCxuKXt0
aGlzLl8rPSJMIisodGhpcy5feDE9K3QpKyIsIisodGhpcy5feTE9K24pfSxxdWFkcmF0aWNDdXJ2
ZVRvOmZ1bmN0aW9uKHQsbixlLHIpe3RoaXMuXys9IlEiKyArdCsiLCIrICtuKyIsIisodGhpcy5f
eDE9K2UpKyIsIisodGhpcy5feTE9K3IpfSxiZXppZXJDdXJ2ZVRvOmZ1bmN0aW9uKHQsbixlLHIs
aSxvKXt0aGlzLl8rPSJDIisgK3QrIiwiKyArbisiLCIrICtlKyIsIisgK3IrIiwiKyh0aGlzLl94
MT0raSkrIiwiKyh0aGlzLl95MT0rbyl9LGFyY1RvOmZ1bmN0aW9uKHQsbixlLHIsaSl7dD0rdCxu
PStuLGU9K2Uscj0rcixpPStpO3ZhciBvPXRoaXMuX3gxLHU9dGhpcy5feTEsYT1lLXQsYz1yLW4s
cz1vLXQsZj11LW4sbD1zKnMrZipmO2lmKGk8MCl0aHJvdyBuZXcgRXJyb3IoIm5lZ2F0aXZlIHJh
ZGl1czogIitpKTtpZihudWxsPT09dGhpcy5feDEpdGhpcy5fKz0iTSIrKHRoaXMuX3gxPXQpKyIs
IisodGhpcy5feTE9bik7ZWxzZSBpZihsPjFlLTYpaWYoTWF0aC5hYnMoZiphLWMqcyk+MWUtNiYm
aSl7dmFyIGg9ZS1vLHA9ci11LGQ9YSphK2MqYyx2PWgqaCtwKnAsZz1NYXRoLnNxcnQoZCksXz1N
YXRoLnNxcnQobCkseT1pKk1hdGgudGFuKCh5aC1NYXRoLmFjb3MoKGQrbC12KS8oMipnKl8pKSkv
MiksbT15L18seD15L2c7TWF0aC5hYnMobS0xKT4xZS02JiYodGhpcy5fKz0iTCIrKHQrbSpzKSsi
LCIrKG4rbSpmKSksdGhpcy5fKz0iQSIraSsiLCIraSsiLDAsMCwiKyArKGYqaD5zKnApKyIsIiso
dGhpcy5feDE9dCt4KmEpKyIsIisodGhpcy5feTE9bit4KmMpfWVsc2UgdGhpcy5fKz0iTCIrKHRo
aXMuX3gxPXQpKyIsIisodGhpcy5feTE9bik7ZWxzZTt9LGFyYzpmdW5jdGlvbih0LG4sZSxyLGks
byl7dD0rdCxuPStuO3ZhciB1PShlPStlKSpNYXRoLmNvcyhyKSxhPWUqTWF0aC5zaW4ociksYz10
K3Uscz1uK2EsZj0xXm8sbD1vP3ItaTppLXI7aWYoZTwwKXRocm93IG5ldyBFcnJvcigibmVnYXRp
dmUgcmFkaXVzOiAiK2UpO251bGw9PT10aGlzLl94MT90aGlzLl8rPSJNIitjKyIsIitzOihNYXRo
LmFicyh0aGlzLl94MS1jKT4xZS02fHxNYXRoLmFicyh0aGlzLl95MS1zKT4xZS02KSYmKHRoaXMu
Xys9IkwiK2MrIiwiK3MpLGUmJihsPDAmJihsPWwlbWgrbWgpLGw+eGg/dGhpcy5fKz0iQSIrZSsi
LCIrZSsiLDAsMSwiK2YrIiwiKyh0LXUpKyIsIisobi1hKSsiQSIrZSsiLCIrZSsiLDAsMSwiK2Yr
IiwiKyh0aGlzLl94MT1jKSsiLCIrKHRoaXMuX3kxPXMpOmw+MWUtNiYmKHRoaXMuXys9IkEiK2Ur
IiwiK2UrIiwwLCIrICsobD49eWgpKyIsIitmKyIsIisodGhpcy5feDE9dCtlKk1hdGguY29zKGkp
KSsiLCIrKHRoaXMuX3kxPW4rZSpNYXRoLnNpbihpKSkpKX0scmVjdDpmdW5jdGlvbih0LG4sZSxy
KXt0aGlzLl8rPSJNIisodGhpcy5feDA9dGhpcy5feDE9K3QpKyIsIisodGhpcy5feTA9dGhpcy5f
eTE9K24pKyJoIisgK2UrInYiKyArcisiaCIrLWUrIloifSx0b1N0cmluZzpmdW5jdGlvbigpe3Jl
dHVybiB0aGlzLl99fTtjZS5wcm90b3R5cGU9c2UucHJvdG90eXBlPXtjb25zdHJ1Y3RvcjpjZSxo
YXM6ZnVuY3Rpb24odCl7cmV0dXJuIiQiK3QgaW4gdGhpc30sZ2V0OmZ1bmN0aW9uKHQpe3JldHVy
biB0aGlzWyIkIit0XX0sc2V0OmZ1bmN0aW9uKHQsbil7cmV0dXJuIHRoaXNbIiQiK3RdPW4sdGhp
c30scmVtb3ZlOmZ1bmN0aW9uKHQpe3ZhciBuPSIkIit0O3JldHVybiBuIGluIHRoaXMmJmRlbGV0
ZSB0aGlzW25dfSxjbGVhcjpmdW5jdGlvbigpe2Zvcih2YXIgdCBpbiB0aGlzKSIkIj09PXRbMF0m
JmRlbGV0ZSB0aGlzW3RdfSxrZXlzOmZ1bmN0aW9uKCl7dmFyIHQ9W107Zm9yKHZhciBuIGluIHRo
aXMpIiQiPT09blswXSYmdC5wdXNoKG4uc2xpY2UoMSkpO3JldHVybiB0fSx2YWx1ZXM6ZnVuY3Rp
b24oKXt2YXIgdD1bXTtmb3IodmFyIG4gaW4gdGhpcykiJCI9PT1uWzBdJiZ0LnB1c2godGhpc1tu
XSk7cmV0dXJuIHR9LGVudHJpZXM6ZnVuY3Rpb24oKXt2YXIgdD1bXTtmb3IodmFyIG4gaW4gdGhp
cykiJCI9PT1uWzBdJiZ0LnB1c2goe2tleTpuLnNsaWNlKDEpLHZhbHVlOnRoaXNbbl19KTtyZXR1
cm4gdH0sc2l6ZTpmdW5jdGlvbigpe3ZhciB0PTA7Zm9yKHZhciBuIGluIHRoaXMpIiQiPT09blsw
XSYmKyt0O3JldHVybiB0fSxlbXB0eTpmdW5jdGlvbigpe2Zvcih2YXIgdCBpbiB0aGlzKWlmKCIk
Ij09PXRbMF0pcmV0dXJuITE7cmV0dXJuITB9LGVhY2g6ZnVuY3Rpb24odCl7Zm9yKHZhciBuIGlu
IHRoaXMpIiQiPT09blswXSYmdCh0aGlzW25dLG4uc2xpY2UoMSksdGhpcyl9fTt2YXIgYmg9c2Uu
cHJvdG90eXBlO2RlLnByb3RvdHlwZT12ZS5wcm90b3R5cGU9e2NvbnN0cnVjdG9yOmRlLGhhczpi
aC5oYXMsYWRkOmZ1bmN0aW9uKHQpe3JldHVybiB0Kz0iIix0aGlzWyIkIit0XT10LHRoaXN9LHJl
bW92ZTpiaC5yZW1vdmUsY2xlYXI6YmguY2xlYXIsdmFsdWVzOmJoLmtleXMsc2l6ZTpiaC5zaXpl
LGVtcHR5OmJoLmVtcHR5LGVhY2g6YmguZWFjaH07dmFyIHdoPXt9LE1oPXt9LFRoPTM0LE5oPTEw
LGtoPTEzLFNoPV9lKCIsIiksRWg9U2gucGFyc2UsQWg9U2gucGFyc2VSb3dzLENoPVNoLmZvcm1h
dCx6aD1TaC5mb3JtYXRSb3dzLFBoPV9lKCJcdCIpLFJoPVBoLnBhcnNlLExoPVBoLnBhcnNlUm93
cyxxaD1QaC5mb3JtYXQsRGg9UGguZm9ybWF0Um93cyxVaD1UZS5wcm90b3R5cGU9TmUucHJvdG90
eXBlO1VoLmNvcHk9ZnVuY3Rpb24oKXt2YXIgdCxuLGU9bmV3IE5lKHRoaXMuX3gsdGhpcy5feSx0
aGlzLl94MCx0aGlzLl95MCx0aGlzLl94MSx0aGlzLl95MSkscj10aGlzLl9yb290O2lmKCFyKXJl
dHVybiBlO2lmKCFyLmxlbmd0aClyZXR1cm4gZS5fcm9vdD1rZShyKSxlO2Zvcih0PVt7c291cmNl
OnIsdGFyZ2V0OmUuX3Jvb3Q9bmV3IEFycmF5KDQpfV07cj10LnBvcCgpOylmb3IodmFyIGk9MDtp
PDQ7KytpKShuPXIuc291cmNlW2ldKSYmKG4ubGVuZ3RoP3QucHVzaCh7c291cmNlOm4sdGFyZ2V0
OnIudGFyZ2V0W2ldPW5ldyBBcnJheSg0KX0pOnIudGFyZ2V0W2ldPWtlKG4pKTtyZXR1cm4gZX0s
VWguYWRkPWZ1bmN0aW9uKHQpe3ZhciBuPSt0aGlzLl94LmNhbGwobnVsbCx0KSxlPSt0aGlzLl95
LmNhbGwobnVsbCx0KTtyZXR1cm4geGUodGhpcy5jb3ZlcihuLGUpLG4sZSx0KX0sVWguYWRkQWxs
PWZ1bmN0aW9uKHQpe3ZhciBuLGUscixpLG89dC5sZW5ndGgsdT1uZXcgQXJyYXkobyksYT1uZXcg
QXJyYXkobyksYz0xLzAscz0xLzAsZj0tMS8wLGw9LTEvMDtmb3IoZT0wO2U8bzsrK2UpaXNOYU4o
cj0rdGhpcy5feC5jYWxsKG51bGwsbj10W2VdKSl8fGlzTmFOKGk9K3RoaXMuX3kuY2FsbChudWxs
LG4pKXx8KHVbZV09cixhW2VdPWkscjxjJiYoYz1yKSxyPmYmJihmPXIpLGk8cyYmKHM9aSksaT5s
JiYobD1pKSk7Zm9yKGY8YyYmKGM9dGhpcy5feDAsZj10aGlzLl94MSksbDxzJiYocz10aGlzLl95
MCxsPXRoaXMuX3kxKSx0aGlzLmNvdmVyKGMscykuY292ZXIoZixsKSxlPTA7ZTxvOysrZSl4ZSh0
aGlzLHVbZV0sYVtlXSx0W2VdKTtyZXR1cm4gdGhpc30sVWguY292ZXI9ZnVuY3Rpb24odCxuKXtp
Zihpc05hTih0PSt0KXx8aXNOYU4obj0rbikpcmV0dXJuIHRoaXM7dmFyIGU9dGhpcy5feDAscj10
aGlzLl95MCxpPXRoaXMuX3gxLG89dGhpcy5feTE7aWYoaXNOYU4oZSkpaT0oZT1NYXRoLmZsb29y
KHQpKSsxLG89KHI9TWF0aC5mbG9vcihuKSkrMTtlbHNle2lmKCEoZT50fHx0Pml8fHI+bnx8bj5v
KSlyZXR1cm4gdGhpczt2YXIgdSxhLGM9aS1lLHM9dGhpcy5fcm9vdDtzd2l0Y2goYT0objwocitv
KS8yKTw8MXx0PChlK2kpLzIpe2Nhc2UgMDpkb3t1PW5ldyBBcnJheSg0KSx1W2FdPXMscz11fXdo
aWxlKGMqPTIsaT1lK2Msbz1yK2MsdD5pfHxuPm8pO2JyZWFrO2Nhc2UgMTpkb3t1PW5ldyBBcnJh
eSg0KSx1W2FdPXMscz11fXdoaWxlKGMqPTIsZT1pLWMsbz1yK2MsZT50fHxuPm8pO2JyZWFrO2Nh
c2UgMjpkb3t1PW5ldyBBcnJheSg0KSx1W2FdPXMscz11fXdoaWxlKGMqPTIsaT1lK2Mscj1vLWMs
dD5pfHxyPm4pO2JyZWFrO2Nhc2UgMzpkb3t1PW5ldyBBcnJheSg0KSx1W2FdPXMscz11fXdoaWxl
KGMqPTIsZT1pLWMscj1vLWMsZT50fHxyPm4pfXRoaXMuX3Jvb3QmJnRoaXMuX3Jvb3QubGVuZ3Ro
JiYodGhpcy5fcm9vdD1zKX1yZXR1cm4gdGhpcy5feDA9ZSx0aGlzLl95MD1yLHRoaXMuX3gxPWks
dGhpcy5feTE9byx0aGlzfSxVaC5kYXRhPWZ1bmN0aW9uKCl7dmFyIHQ9W107cmV0dXJuIHRoaXMu
dmlzaXQoZnVuY3Rpb24obil7aWYoIW4ubGVuZ3RoKWRve3QucHVzaChuLmRhdGEpfXdoaWxlKG49
bi5uZXh0KX0pLHR9LFVoLmV4dGVudD1mdW5jdGlvbih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0
aD90aGlzLmNvdmVyKCt0WzBdWzBdLCt0WzBdWzFdKS5jb3ZlcigrdFsxXVswXSwrdFsxXVsxXSk6
aXNOYU4odGhpcy5feDApP3ZvaWQgMDpbW3RoaXMuX3gwLHRoaXMuX3kwXSxbdGhpcy5feDEsdGhp
cy5feTFdXX0sVWguZmluZD1mdW5jdGlvbih0LG4sZSl7dmFyIHIsaSxvLHUsYSxjLHMsZj10aGlz
Ll94MCxsPXRoaXMuX3kwLGg9dGhpcy5feDEscD10aGlzLl95MSxkPVtdLHY9dGhpcy5fcm9vdDtm
b3IodiYmZC5wdXNoKG5ldyBiZSh2LGYsbCxoLHApKSxudWxsPT1lP2U9MS8wOihmPXQtZSxsPW4t
ZSxoPXQrZSxwPW4rZSxlKj1lKTtjPWQucG9wKCk7KWlmKCEoISh2PWMubm9kZSl8fChpPWMueDAp
Pmh8fChvPWMueTApPnB8fCh1PWMueDEpPGZ8fChhPWMueTEpPGwpKWlmKHYubGVuZ3RoKXt2YXIg
Zz0oaSt1KS8yLF89KG8rYSkvMjtkLnB1c2gobmV3IGJlKHZbM10sZyxfLHUsYSksbmV3IGJlKHZb
Ml0saSxfLGcsYSksbmV3IGJlKHZbMV0sZyxvLHUsXyksbmV3IGJlKHZbMF0saSxvLGcsXykpLChz
PShuPj1fKTw8MXx0Pj1nKSYmKGM9ZFtkLmxlbmd0aC0xXSxkW2QubGVuZ3RoLTFdPWRbZC5sZW5n
dGgtMS1zXSxkW2QubGVuZ3RoLTEtc109Yyl9ZWxzZXt2YXIgeT10LSt0aGlzLl94LmNhbGwobnVs
bCx2LmRhdGEpLG09bi0rdGhpcy5feS5jYWxsKG51bGwsdi5kYXRhKSx4PXkqeSttKm07aWYoeDxl
KXt2YXIgYj1NYXRoLnNxcnQoZT14KTtmPXQtYixsPW4tYixoPXQrYixwPW4rYixyPXYuZGF0YX19
cmV0dXJuIHJ9LFVoLnJlbW92ZT1mdW5jdGlvbih0KXtpZihpc05hTihvPSt0aGlzLl94LmNhbGwo
bnVsbCx0KSl8fGlzTmFOKHU9K3RoaXMuX3kuY2FsbChudWxsLHQpKSlyZXR1cm4gdGhpczt2YXIg
bixlLHIsaSxvLHUsYSxjLHMsZixsLGgscD10aGlzLl9yb290LGQ9dGhpcy5feDAsdj10aGlzLl95
MCxnPXRoaXMuX3gxLF89dGhpcy5feTE7aWYoIXApcmV0dXJuIHRoaXM7aWYocC5sZW5ndGgpZm9y
KDs7KXtpZigocz1vPj0oYT0oZCtnKS8yKSk/ZD1hOmc9YSwoZj11Pj0oYz0oditfKS8yKSk/dj1j
Ol89YyxuPXAsIShwPXBbbD1mPDwxfHNdKSlyZXR1cm4gdGhpcztpZighcC5sZW5ndGgpYnJlYWs7
KG5bbCsxJjNdfHxuW2wrMiYzXXx8bltsKzMmM10pJiYoZT1uLGg9bCl9Zm9yKDtwLmRhdGEhPT10
OylpZihyPXAsIShwPXAubmV4dCkpcmV0dXJuIHRoaXM7cmV0dXJuKGk9cC5uZXh0KSYmZGVsZXRl
IHAubmV4dCxyPyhpP3IubmV4dD1pOmRlbGV0ZSByLm5leHQsdGhpcyk6bj8oaT9uW2xdPWk6ZGVs
ZXRlIG5bbF0sKHA9blswXXx8blsxXXx8blsyXXx8blszXSkmJnA9PT0oblszXXx8blsyXXx8blsx
XXx8blswXSkmJiFwLmxlbmd0aCYmKGU/ZVtoXT1wOnRoaXMuX3Jvb3Q9cCksdGhpcyk6KHRoaXMu
X3Jvb3Q9aSx0aGlzKX0sVWgucmVtb3ZlQWxsPWZ1bmN0aW9uKHQpe2Zvcih2YXIgbj0wLGU9dC5s
ZW5ndGg7bjxlOysrbil0aGlzLnJlbW92ZSh0W25dKTtyZXR1cm4gdGhpc30sVWgucm9vdD1mdW5j
dGlvbigpe3JldHVybiB0aGlzLl9yb290fSxVaC5zaXplPWZ1bmN0aW9uKCl7dmFyIHQ9MDtyZXR1
cm4gdGhpcy52aXNpdChmdW5jdGlvbihuKXtpZighbi5sZW5ndGgpZG97Kyt0fXdoaWxlKG49bi5u
ZXh0KX0pLHR9LFVoLnZpc2l0PWZ1bmN0aW9uKHQpe3ZhciBuLGUscixpLG8sdSxhPVtdLGM9dGhp
cy5fcm9vdDtmb3IoYyYmYS5wdXNoKG5ldyBiZShjLHRoaXMuX3gwLHRoaXMuX3kwLHRoaXMuX3gx
LHRoaXMuX3kxKSk7bj1hLnBvcCgpOylpZighdChjPW4ubm9kZSxyPW4ueDAsaT1uLnkwLG89bi54
MSx1PW4ueTEpJiZjLmxlbmd0aCl7dmFyIHM9KHIrbykvMixmPShpK3UpLzI7KGU9Y1szXSkmJmEu
cHVzaChuZXcgYmUoZSxzLGYsbyx1KSksKGU9Y1syXSkmJmEucHVzaChuZXcgYmUoZSxyLGYscyx1
KSksKGU9Y1sxXSkmJmEucHVzaChuZXcgYmUoZSxzLGksbyxmKSksKGU9Y1swXSkmJmEucHVzaChu
ZXcgYmUoZSxyLGkscyxmKSl9cmV0dXJuIHRoaXN9LFVoLnZpc2l0QWZ0ZXI9ZnVuY3Rpb24odCl7
dmFyIG4sZT1bXSxyPVtdO2Zvcih0aGlzLl9yb290JiZlLnB1c2gobmV3IGJlKHRoaXMuX3Jvb3Qs
dGhpcy5feDAsdGhpcy5feTAsdGhpcy5feDEsdGhpcy5feTEpKTtuPWUucG9wKCk7KXt2YXIgaT1u
Lm5vZGU7aWYoaS5sZW5ndGgpe3ZhciBvLHU9bi54MCxhPW4ueTAsYz1uLngxLHM9bi55MSxmPSh1
K2MpLzIsbD0oYStzKS8yOyhvPWlbMF0pJiZlLnB1c2gobmV3IGJlKG8sdSxhLGYsbCkpLChvPWlb
MV0pJiZlLnB1c2gobmV3IGJlKG8sZixhLGMsbCkpLChvPWlbMl0pJiZlLnB1c2gobmV3IGJlKG8s
dSxsLGYscykpLChvPWlbM10pJiZlLnB1c2gobmV3IGJlKG8sZixsLGMscykpfXIucHVzaChuKX1m
b3IoO249ci5wb3AoKTspdChuLm5vZGUsbi54MCxuLnkwLG4ueDEsbi55MSk7cmV0dXJuIHRoaXN9
LFVoLng9ZnVuY3Rpb24odCl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KHRoaXMuX3g9dCx0aGlz
KTp0aGlzLl94fSxVaC55PWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyh0aGlz
Ll95PXQsdGhpcyk6dGhpcy5feX07dmFyIE9oLEZoPTEwLEloPU1hdGguUEkqKDMtTWF0aC5zcXJ0
KDUpKSxZaD17IiI6ZnVuY3Rpb24odCxuKXt0OmZvcih2YXIgZSxyPSh0PXQudG9QcmVjaXNpb24o
bikpLmxlbmd0aCxpPTEsbz0tMTtpPHI7KytpKXN3aXRjaCh0W2ldKXtjYXNlIi4iOm89ZT1pO2Jy
ZWFrO2Nhc2UiMCI6MD09PW8mJihvPWkpLGU9aTticmVhaztjYXNlImUiOmJyZWFrIHQ7ZGVmYXVs
dDpvPjAmJihvPTApfXJldHVybiBvPjA/dC5zbGljZSgwLG8pK3Quc2xpY2UoZSsxKTp0fSwiJSI6
ZnVuY3Rpb24odCxuKXtyZXR1cm4oMTAwKnQpLnRvRml4ZWQobil9LGI6ZnVuY3Rpb24odCl7cmV0
dXJuIE1hdGgucm91bmQodCkudG9TdHJpbmcoMil9LGM6ZnVuY3Rpb24odCl7cmV0dXJuIHQrIiJ9
LGQ6ZnVuY3Rpb24odCl7cmV0dXJuIE1hdGgucm91bmQodCkudG9TdHJpbmcoMTApfSxlOmZ1bmN0
aW9uKHQsbil7cmV0dXJuIHQudG9FeHBvbmVudGlhbChuKX0sZjpmdW5jdGlvbih0LG4pe3JldHVy
biB0LnRvRml4ZWQobil9LGc6ZnVuY3Rpb24odCxuKXtyZXR1cm4gdC50b1ByZWNpc2lvbihuKX0s
bzpmdW5jdGlvbih0KXtyZXR1cm4gTWF0aC5yb3VuZCh0KS50b1N0cmluZyg4KX0scDpmdW5jdGlv
bih0LG4pe3JldHVybiBxZSgxMDAqdCxuKX0scjpxZSxzOmZ1bmN0aW9uKHQsbil7dmFyIGU9UmUo
dCxuKTtpZighZSlyZXR1cm4gdCsiIjt2YXIgcj1lWzBdLGk9ZVsxXSxvPWktKE9oPTMqTWF0aC5t
YXgoLTgsTWF0aC5taW4oOCxNYXRoLmZsb29yKGkvMykpKSkrMSx1PXIubGVuZ3RoO3JldHVybiBv
PT09dT9yOm8+dT9yK25ldyBBcnJheShvLXUrMSkuam9pbigiMCIpOm8+MD9yLnNsaWNlKDAsbykr
Ii4iK3Iuc2xpY2Uobyk6IjAuIituZXcgQXJyYXkoMS1vKS5qb2luKCIwIikrUmUodCxNYXRoLm1h
eCgwLG4rby0xKSlbMF19LFg6ZnVuY3Rpb24odCl7cmV0dXJuIE1hdGgucm91bmQodCkudG9TdHJp
bmcoMTYpLnRvVXBwZXJDYXNlKCl9LHg6ZnVuY3Rpb24odCl7cmV0dXJuIE1hdGgucm91bmQodCku
dG9TdHJpbmcoMTYpfX0sQmg9L14oPzooLik/KFs8Pj1eXSkpPyhbK1wtXCggXSk/KFskI10pPygw
KT8oXGQrKT8oLCk/KFwuXGQrKT8oW2EteiVdKT8kL2k7RGUucHJvdG90eXBlPVVlLnByb3RvdHlw
ZSxVZS5wcm90b3R5cGUudG9TdHJpbmc9ZnVuY3Rpb24oKXtyZXR1cm4gdGhpcy5maWxsK3RoaXMu
YWxpZ24rdGhpcy5zaWduK3RoaXMuc3ltYm9sKyh0aGlzLnplcm8/IjAiOiIiKSsobnVsbD09dGhp
cy53aWR0aD8iIjpNYXRoLm1heCgxLDB8dGhpcy53aWR0aCkpKyh0aGlzLmNvbW1hPyIsIjoiIikr
KG51bGw9PXRoaXMucHJlY2lzaW9uPyIiOiIuIitNYXRoLm1heCgwLDB8dGhpcy5wcmVjaXNpb24p
KSt0aGlzLnR5cGV9O3ZhciBIaCxqaD1bInkiLCJ6IiwiYSIsImYiLCJwIiwibiIsIsK1IiwibSIs
IiIsImsiLCJNIiwiRyIsIlQiLCJQIiwiRSIsIloiLCJZIl07SWUoe2RlY2ltYWw6Ii4iLHRob3Vz
YW5kczoiLCIsZ3JvdXBpbmc6WzNdLGN1cnJlbmN5OlsiJCIsIiJdfSksWGUucHJvdG90eXBlPXtj
b25zdHJ1Y3RvcjpYZSxyZXNldDpmdW5jdGlvbigpe3RoaXMucz10aGlzLnQ9MH0sYWRkOmZ1bmN0
aW9uKHQpe1ZlKHdwLHQsdGhpcy50KSxWZSh0aGlzLHdwLnMsdGhpcy5zKSx0aGlzLnM/dGhpcy50
Kz13cC50OnRoaXMucz13cC50fSx2YWx1ZU9mOmZ1bmN0aW9uKCl7cmV0dXJuIHRoaXMuc319O3Zh
ciBYaCxWaCwkaCxXaCxaaCxHaCxRaCxKaCxLaCx0cCxucCxlcCxycCxpcCxvcCx1cCxhcCxjcCxz
cCxmcCxscCxocCxwcCxkcCx2cCxncCxfcCx5cCxtcCx4cCxicCx3cD1uZXcgWGUsTXA9MWUtNixU
cD0xZS0xMixOcD1NYXRoLlBJLGtwPU5wLzIsU3A9TnAvNCxFcD0yKk5wLEFwPTE4MC9OcCxDcD1O
cC8xODAsenA9TWF0aC5hYnMsUHA9TWF0aC5hdGFuLFJwPU1hdGguYXRhbjIsTHA9TWF0aC5jb3Ms
cXA9TWF0aC5jZWlsLERwPU1hdGguZXhwLFVwPU1hdGgubG9nLE9wPU1hdGgucG93LEZwPU1hdGgu
c2luLElwPU1hdGguc2lnbnx8ZnVuY3Rpb24odCl7cmV0dXJuIHQ+MD8xOnQ8MD8tMTowfSxZcD1N
YXRoLnNxcnQsQnA9TWF0aC50YW4sSHA9e0ZlYXR1cmU6ZnVuY3Rpb24odCxuKXtRZSh0Lmdlb21l
dHJ5LG4pfSxGZWF0dXJlQ29sbGVjdGlvbjpmdW5jdGlvbih0LG4pe2Zvcih2YXIgZT10LmZlYXR1
cmVzLHI9LTEsaT1lLmxlbmd0aDsrK3I8aTspUWUoZVtyXS5nZW9tZXRyeSxuKX19LGpwPXtTcGhl
cmU6ZnVuY3Rpb24odCxuKXtuLnNwaGVyZSgpfSxQb2ludDpmdW5jdGlvbih0LG4pe3Q9dC5jb29y
ZGluYXRlcyxuLnBvaW50KHRbMF0sdFsxXSx0WzJdKX0sTXVsdGlQb2ludDpmdW5jdGlvbih0LG4p
e2Zvcih2YXIgZT10LmNvb3JkaW5hdGVzLHI9LTEsaT1lLmxlbmd0aDsrK3I8aTspdD1lW3JdLG4u
cG9pbnQodFswXSx0WzFdLHRbMl0pfSxMaW5lU3RyaW5nOmZ1bmN0aW9uKHQsbil7SmUodC5jb29y
ZGluYXRlcyxuLDApfSxNdWx0aUxpbmVTdHJpbmc6ZnVuY3Rpb24odCxuKXtmb3IodmFyIGU9dC5j
b29yZGluYXRlcyxyPS0xLGk9ZS5sZW5ndGg7KytyPGk7KUplKGVbcl0sbiwwKX0sUG9seWdvbjpm
dW5jdGlvbih0LG4pe0tlKHQuY29vcmRpbmF0ZXMsbil9LE11bHRpUG9seWdvbjpmdW5jdGlvbih0
LG4pe2Zvcih2YXIgZT10LmNvb3JkaW5hdGVzLHI9LTEsaT1lLmxlbmd0aDsrK3I8aTspS2UoZVty
XSxuKX0sR2VvbWV0cnlDb2xsZWN0aW9uOmZ1bmN0aW9uKHQsbil7Zm9yKHZhciBlPXQuZ2VvbWV0
cmllcyxyPS0xLGk9ZS5sZW5ndGg7KytyPGk7KVFlKGVbcl0sbil9fSxYcD1qZSgpLFZwPWplKCks
JHA9e3BvaW50OkdlLGxpbmVTdGFydDpHZSxsaW5lRW5kOkdlLHBvbHlnb25TdGFydDpmdW5jdGlv
bigpe1hwLnJlc2V0KCksJHAubGluZVN0YXJ0PW5yLCRwLmxpbmVFbmQ9ZXJ9LHBvbHlnb25FbmQ6
ZnVuY3Rpb24oKXt2YXIgdD0rWHA7VnAuYWRkKHQ8MD9FcCt0OnQpLHRoaXMubGluZVN0YXJ0PXRo
aXMubGluZUVuZD10aGlzLnBvaW50PUdlfSxzcGhlcmU6ZnVuY3Rpb24oKXtWcC5hZGQoRXApfX0s
V3A9amUoKSxacD17cG9pbnQ6aHIsbGluZVN0YXJ0OmRyLGxpbmVFbmQ6dnIscG9seWdvblN0YXJ0
OmZ1bmN0aW9uKCl7WnAucG9pbnQ9Z3IsWnAubGluZVN0YXJ0PV9yLFpwLmxpbmVFbmQ9eXIsV3Au
cmVzZXQoKSwkcC5wb2x5Z29uU3RhcnQoKX0scG9seWdvbkVuZDpmdW5jdGlvbigpeyRwLnBvbHln
b25FbmQoKSxacC5wb2ludD1ocixacC5saW5lU3RhcnQ9ZHIsWnAubGluZUVuZD12cixYcDwwPyhH
aD0tKEpoPTE4MCksUWg9LShLaD05MCkpOldwPk1wP0toPTkwOldwPC1NcCYmKFFoPS05MCksb3Bb
MF09R2gsb3BbMV09Smh9fSxHcD17c3BoZXJlOkdlLHBvaW50OndyLGxpbmVTdGFydDpUcixsaW5l
RW5kOlNyLHBvbHlnb25TdGFydDpmdW5jdGlvbigpe0dwLmxpbmVTdGFydD1FcixHcC5saW5lRW5k
PUFyfSxwb2x5Z29uRW5kOmZ1bmN0aW9uKCl7R3AubGluZVN0YXJ0PVRyLEdwLmxpbmVFbmQ9U3J9
fTtMci5pbnZlcnQ9THI7dmFyIFFwLEpwLEtwLHRkLG5kLGVkLHJkLGlkLG9kLHVkLGFkLGNkPWpl
KCksc2Q9V3IoZnVuY3Rpb24oKXtyZXR1cm4hMH0sZnVuY3Rpb24odCl7dmFyIG4sZT1OYU4scj1O
YU4saT1OYU47cmV0dXJue2xpbmVTdGFydDpmdW5jdGlvbigpe3QubGluZVN0YXJ0KCksbj0xfSxw
b2ludDpmdW5jdGlvbihvLHUpe3ZhciBhPW8+MD9OcDotTnAsYz16cChvLWUpO3pwKGMtTnApPE1w
Pyh0LnBvaW50KGUscj0ocit1KS8yPjA/a3A6LWtwKSx0LnBvaW50KGksciksdC5saW5lRW5kKCks
dC5saW5lU3RhcnQoKSx0LnBvaW50KGEsciksdC5wb2ludChvLHIpLG49MCk6aSE9PWEmJmM+PU5w
JiYoenAoZS1pKTxNcCYmKGUtPWkqTXApLHpwKG8tYSk8TXAmJihvLT1hKk1wKSxyPWZ1bmN0aW9u
KHQsbixlLHIpe3ZhciBpLG8sdT1GcCh0LWUpO3JldHVybiB6cCh1KT5NcD9QcCgoRnAobikqKG89
THAocikpKkZwKGUpLUZwKHIpKihpPUxwKG4pKSpGcCh0KSkvKGkqbyp1KSk6KG4rcikvMn0oZSxy
LG8sdSksdC5wb2ludChpLHIpLHQubGluZUVuZCgpLHQubGluZVN0YXJ0KCksdC5wb2ludChhLHIp
LG49MCksdC5wb2ludChlPW8scj11KSxpPWF9LGxpbmVFbmQ6ZnVuY3Rpb24oKXt0LmxpbmVFbmQo
KSxlPXI9TmFOfSxjbGVhbjpmdW5jdGlvbigpe3JldHVybiAyLW59fX0sZnVuY3Rpb24odCxuLGUs
cil7dmFyIGk7aWYobnVsbD09dClpPWUqa3Asci5wb2ludCgtTnAsaSksci5wb2ludCgwLGkpLHIu
cG9pbnQoTnAsaSksci5wb2ludChOcCwwKSxyLnBvaW50KE5wLC1pKSxyLnBvaW50KDAsLWkpLHIu
cG9pbnQoLU5wLC1pKSxyLnBvaW50KC1OcCwwKSxyLnBvaW50KC1OcCxpKTtlbHNlIGlmKHpwKHRb
MF0tblswXSk+TXApe3ZhciBvPXRbMF08blswXT9OcDotTnA7aT1lKm8vMixyLnBvaW50KC1vLGkp
LHIucG9pbnQoMCxpKSxyLnBvaW50KG8saSl9ZWxzZSByLnBvaW50KG5bMF0sblsxXSl9LFstTnAs
LWtwXSksZmQ9MWU5LGxkPS1mZCxoZD1qZSgpLHBkPXtzcGhlcmU6R2UscG9pbnQ6R2UsbGluZVN0
YXJ0OmZ1bmN0aW9uKCl7cGQucG9pbnQ9dGkscGQubGluZUVuZD1Lcn0sbGluZUVuZDpHZSxwb2x5
Z29uU3RhcnQ6R2UscG9seWdvbkVuZDpHZX0sZGQ9W251bGwsbnVsbF0sdmQ9e3R5cGU6IkxpbmVT
dHJpbmciLGNvb3JkaW5hdGVzOmRkfSxnZD17RmVhdHVyZTpmdW5jdGlvbih0LG4pe3JldHVybiBp
aSh0Lmdlb21ldHJ5LG4pfSxGZWF0dXJlQ29sbGVjdGlvbjpmdW5jdGlvbih0LG4pe2Zvcih2YXIg
ZT10LmZlYXR1cmVzLHI9LTEsaT1lLmxlbmd0aDsrK3I8aTspaWYoaWkoZVtyXS5nZW9tZXRyeSxu
KSlyZXR1cm4hMDtyZXR1cm4hMX19LF9kPXtTcGhlcmU6ZnVuY3Rpb24oKXtyZXR1cm4hMH0sUG9p
bnQ6ZnVuY3Rpb24odCxuKXtyZXR1cm4gb2kodC5jb29yZGluYXRlcyxuKX0sTXVsdGlQb2ludDpm
dW5jdGlvbih0LG4pe2Zvcih2YXIgZT10LmNvb3JkaW5hdGVzLHI9LTEsaT1lLmxlbmd0aDsrK3I8
aTspaWYob2koZVtyXSxuKSlyZXR1cm4hMDtyZXR1cm4hMX0sTGluZVN0cmluZzpmdW5jdGlvbih0
LG4pe3JldHVybiB1aSh0LmNvb3JkaW5hdGVzLG4pfSxNdWx0aUxpbmVTdHJpbmc6ZnVuY3Rpb24o
dCxuKXtmb3IodmFyIGU9dC5jb29yZGluYXRlcyxyPS0xLGk9ZS5sZW5ndGg7KytyPGk7KWlmKHVp
KGVbcl0sbikpcmV0dXJuITA7cmV0dXJuITF9LFBvbHlnb246ZnVuY3Rpb24odCxuKXtyZXR1cm4g
YWkodC5jb29yZGluYXRlcyxuKX0sTXVsdGlQb2x5Z29uOmZ1bmN0aW9uKHQsbil7Zm9yKHZhciBl
PXQuY29vcmRpbmF0ZXMscj0tMSxpPWUubGVuZ3RoOysrcjxpOylpZihhaShlW3JdLG4pKXJldHVy
biEwO3JldHVybiExfSxHZW9tZXRyeUNvbGxlY3Rpb246ZnVuY3Rpb24odCxuKXtmb3IodmFyIGU9
dC5nZW9tZXRyaWVzLHI9LTEsaT1lLmxlbmd0aDsrK3I8aTspaWYoaWkoZVtyXSxuKSlyZXR1cm4h
MDtyZXR1cm4hMX19LHlkPWplKCksbWQ9amUoKSx4ZD17cG9pbnQ6R2UsbGluZVN0YXJ0OkdlLGxp
bmVFbmQ6R2UscG9seWdvblN0YXJ0OmZ1bmN0aW9uKCl7eGQubGluZVN0YXJ0PWRpLHhkLmxpbmVF
bmQ9X2l9LHBvbHlnb25FbmQ6ZnVuY3Rpb24oKXt4ZC5saW5lU3RhcnQ9eGQubGluZUVuZD14ZC5w
b2ludD1HZSx5ZC5hZGQoenAobWQpKSxtZC5yZXNldCgpfSxyZXN1bHQ6ZnVuY3Rpb24oKXt2YXIg
dD15ZC8yO3JldHVybiB5ZC5yZXNldCgpLHR9fSxiZD0xLzAsd2Q9YmQsTWQ9LWJkLFRkPU1kLE5k
PXtwb2ludDpmdW5jdGlvbih0LG4pe3Q8YmQmJihiZD10KSx0Pk1kJiYoTWQ9dCksbjx3ZCYmKHdk
PW4pLG4+VGQmJihUZD1uKX0sbGluZVN0YXJ0OkdlLGxpbmVFbmQ6R2UscG9seWdvblN0YXJ0Okdl
LHBvbHlnb25FbmQ6R2UscmVzdWx0OmZ1bmN0aW9uKCl7dmFyIHQ9W1tiZCx3ZF0sW01kLFRkXV07
cmV0dXJuIE1kPVRkPS0od2Q9YmQ9MS8wKSx0fX0sa2Q9MCxTZD0wLEVkPTAsQWQ9MCxDZD0wLHpk
PTAsUGQ9MCxSZD0wLExkPTAscWQ9e3BvaW50OnlpLGxpbmVTdGFydDptaSxsaW5lRW5kOndpLHBv
bHlnb25TdGFydDpmdW5jdGlvbigpe3FkLmxpbmVTdGFydD1NaSxxZC5saW5lRW5kPVRpfSxwb2x5
Z29uRW5kOmZ1bmN0aW9uKCl7cWQucG9pbnQ9eWkscWQubGluZVN0YXJ0PW1pLHFkLmxpbmVFbmQ9
d2l9LHJlc3VsdDpmdW5jdGlvbigpe3ZhciB0PUxkP1tQZC9MZCxSZC9MZF06emQ/W0FkL3pkLENk
L3pkXTpFZD9ba2QvRWQsU2QvRWRdOltOYU4sTmFOXTtyZXR1cm4ga2Q9U2Q9RWQ9QWQ9Q2Q9emQ9
UGQ9UmQ9TGQ9MCx0fX07U2kucHJvdG90eXBlPXtfcmFkaXVzOjQuNSxwb2ludFJhZGl1czpmdW5j
dGlvbih0KXtyZXR1cm4gdGhpcy5fcmFkaXVzPXQsdGhpc30scG9seWdvblN0YXJ0OmZ1bmN0aW9u
KCl7dGhpcy5fbGluZT0wfSxwb2x5Z29uRW5kOmZ1bmN0aW9uKCl7dGhpcy5fbGluZT1OYU59LGxp
bmVTdGFydDpmdW5jdGlvbigpe3RoaXMuX3BvaW50PTB9LGxpbmVFbmQ6ZnVuY3Rpb24oKXswPT09
dGhpcy5fbGluZSYmdGhpcy5fY29udGV4dC5jbG9zZVBhdGgoKSx0aGlzLl9wb2ludD1OYU59LHBv
aW50OmZ1bmN0aW9uKHQsbil7c3dpdGNoKHRoaXMuX3BvaW50KXtjYXNlIDA6dGhpcy5fY29udGV4
dC5tb3ZlVG8odCxuKSx0aGlzLl9wb2ludD0xO2JyZWFrO2Nhc2UgMTp0aGlzLl9jb250ZXh0Lmxp
bmVUbyh0LG4pO2JyZWFrO2RlZmF1bHQ6dGhpcy5fY29udGV4dC5tb3ZlVG8odCt0aGlzLl9yYWRp
dXMsbiksdGhpcy5fY29udGV4dC5hcmModCxuLHRoaXMuX3JhZGl1cywwLEVwKX19LHJlc3VsdDpH
ZX07dmFyIERkLFVkLE9kLEZkLElkLFlkPWplKCksQmQ9e3BvaW50OkdlLGxpbmVTdGFydDpmdW5j
dGlvbigpe0JkLnBvaW50PUVpfSxsaW5lRW5kOmZ1bmN0aW9uKCl7RGQmJkFpKFVkLE9kKSxCZC5w
b2ludD1HZX0scG9seWdvblN0YXJ0OmZ1bmN0aW9uKCl7RGQ9ITB9LHBvbHlnb25FbmQ6ZnVuY3Rp
b24oKXtEZD1udWxsfSxyZXN1bHQ6ZnVuY3Rpb24oKXt2YXIgdD0rWWQ7cmV0dXJuIFlkLnJlc2V0
KCksdH19O0NpLnByb3RvdHlwZT17X3JhZGl1czo0LjUsX2NpcmNsZTp6aSg0LjUpLHBvaW50UmFk
aXVzOmZ1bmN0aW9uKHQpe3JldHVybih0PSt0KSE9PXRoaXMuX3JhZGl1cyYmKHRoaXMuX3JhZGl1
cz10LHRoaXMuX2NpcmNsZT1udWxsKSx0aGlzfSxwb2x5Z29uU3RhcnQ6ZnVuY3Rpb24oKXt0aGlz
Ll9saW5lPTB9LHBvbHlnb25FbmQ6ZnVuY3Rpb24oKXt0aGlzLl9saW5lPU5hTn0sbGluZVN0YXJ0
OmZ1bmN0aW9uKCl7dGhpcy5fcG9pbnQ9MH0sbGluZUVuZDpmdW5jdGlvbigpezA9PT10aGlzLl9s
aW5lJiZ0aGlzLl9zdHJpbmcucHVzaCgiWiIpLHRoaXMuX3BvaW50PU5hTn0scG9pbnQ6ZnVuY3Rp
b24odCxuKXtzd2l0Y2godGhpcy5fcG9pbnQpe2Nhc2UgMDp0aGlzLl9zdHJpbmcucHVzaCgiTSIs
dCwiLCIsbiksdGhpcy5fcG9pbnQ9MTticmVhaztjYXNlIDE6dGhpcy5fc3RyaW5nLnB1c2goIkwi
LHQsIiwiLG4pO2JyZWFrO2RlZmF1bHQ6bnVsbD09dGhpcy5fY2lyY2xlJiYodGhpcy5fY2lyY2xl
PXppKHRoaXMuX3JhZGl1cykpLHRoaXMuX3N0cmluZy5wdXNoKCJNIix0LCIsIixuLHRoaXMuX2Np
cmNsZSl9fSxyZXN1bHQ6ZnVuY3Rpb24oKXtpZih0aGlzLl9zdHJpbmcubGVuZ3RoKXt2YXIgdD10
aGlzLl9zdHJpbmcuam9pbigiIik7cmV0dXJuIHRoaXMuX3N0cmluZz1bXSx0fXJldHVybiBudWxs
fX0sUmkucHJvdG90eXBlPXtjb25zdHJ1Y3RvcjpSaSxwb2ludDpmdW5jdGlvbih0LG4pe3RoaXMu
c3RyZWFtLnBvaW50KHQsbil9LHNwaGVyZTpmdW5jdGlvbigpe3RoaXMuc3RyZWFtLnNwaGVyZSgp
fSxsaW5lU3RhcnQ6ZnVuY3Rpb24oKXt0aGlzLnN0cmVhbS5saW5lU3RhcnQoKX0sbGluZUVuZDpm
dW5jdGlvbigpe3RoaXMuc3RyZWFtLmxpbmVFbmQoKX0scG9seWdvblN0YXJ0OmZ1bmN0aW9uKCl7
dGhpcy5zdHJlYW0ucG9seWdvblN0YXJ0KCl9LHBvbHlnb25FbmQ6ZnVuY3Rpb24oKXt0aGlzLnN0
cmVhbS5wb2x5Z29uRW5kKCl9fTt2YXIgSGQ9MTYsamQ9THAoMzAqQ3ApLFhkPVBpKHtwb2ludDpm
dW5jdGlvbih0LG4pe3RoaXMuc3RyZWFtLnBvaW50KHQqQ3AsbipDcCl9fSksVmQ9VmkoZnVuY3Rp
b24odCl7cmV0dXJuIFlwKDIvKDErdCkpfSk7VmQuaW52ZXJ0PSRpKGZ1bmN0aW9uKHQpe3JldHVy
biAyKldlKHQvMil9KTt2YXIgJGQ9VmkoZnVuY3Rpb24odCl7cmV0dXJuKHQ9JGUodCkpJiZ0L0Zw
KHQpfSk7JGQuaW52ZXJ0PSRpKGZ1bmN0aW9uKHQpe3JldHVybiB0fSksV2kuaW52ZXJ0PWZ1bmN0
aW9uKHQsbil7cmV0dXJuW3QsMipQcChEcChuKSkta3BdfSxKaS5pbnZlcnQ9SmksdG8uaW52ZXJ0
PSRpKFBwKSxlby5pbnZlcnQ9ZnVuY3Rpb24odCxuKXt2YXIgZSxyPW4saT0yNTtkb3t2YXIgbz1y
KnIsdT1vKm87ci09ZT0ociooMS4wMDcyMjYrbyooLjAxNTA4NSt1KiguMDI4ODc0Km8tLjA0NDQ3
NS0uMDA1OTE2KnUpKSktbikvKDEuMDA3MjI2K28qKC4wNDUyNTUrdSooLjI1OTg2NipvLS4zMTEz
MjUtLjAwNTkxNioxMSp1KSkpfXdoaWxlKHpwKGUpPk1wJiYtLWk+MCk7cmV0dXJuW3QvKC44NzA3
KyhvPXIqcikqKG8qKG8qbypvKiguMDAzOTcxLS4wMDE1MjkqbyktLjAxMzc5MSktLjEzMTk3OSkp
LHJdfSxyby5pbnZlcnQ9JGkoV2UpLGlvLmludmVydD0kaShmdW5jdGlvbih0KXtyZXR1cm4gMipQ
cCh0KX0pLG9vLmludmVydD1mdW5jdGlvbih0LG4pe3JldHVyblstbiwyKlBwKERwKHQpKS1rcF19
LHZvLnByb3RvdHlwZT1mby5wcm90b3R5cGU9e2NvbnN0cnVjdG9yOnZvLGNvdW50OmZ1bmN0aW9u
KCl7cmV0dXJuIHRoaXMuZWFjaEFmdGVyKHNvKX0sZWFjaDpmdW5jdGlvbih0KXt2YXIgbixlLHIs
aSxvPXRoaXMsdT1bb107ZG97Zm9yKG49dS5yZXZlcnNlKCksdT1bXTtvPW4ucG9wKCk7KWlmKHQo
byksZT1vLmNoaWxkcmVuKWZvcihyPTAsaT1lLmxlbmd0aDtyPGk7KytyKXUucHVzaChlW3JdKX13
aGlsZSh1Lmxlbmd0aCk7cmV0dXJuIHRoaXN9LGVhY2hBZnRlcjpmdW5jdGlvbih0KXtmb3IodmFy
IG4sZSxyLGk9dGhpcyxvPVtpXSx1PVtdO2k9by5wb3AoKTspaWYodS5wdXNoKGkpLG49aS5jaGls
ZHJlbilmb3IoZT0wLHI9bi5sZW5ndGg7ZTxyOysrZSlvLnB1c2gobltlXSk7Zm9yKDtpPXUucG9w
KCk7KXQoaSk7cmV0dXJuIHRoaXN9LGVhY2hCZWZvcmU6ZnVuY3Rpb24odCl7Zm9yKHZhciBuLGUs
cj10aGlzLGk9W3JdO3I9aS5wb3AoKTspaWYodChyKSxuPXIuY2hpbGRyZW4pZm9yKGU9bi5sZW5n
dGgtMTtlPj0wOy0tZSlpLnB1c2gobltlXSk7cmV0dXJuIHRoaXN9LHN1bTpmdW5jdGlvbih0KXty
ZXR1cm4gdGhpcy5lYWNoQWZ0ZXIoZnVuY3Rpb24obil7Zm9yKHZhciBlPSt0KG4uZGF0YSl8fDAs
cj1uLmNoaWxkcmVuLGk9ciYmci5sZW5ndGg7LS1pPj0wOyllKz1yW2ldLnZhbHVlO24udmFsdWU9
ZX0pfSxzb3J0OmZ1bmN0aW9uKHQpe3JldHVybiB0aGlzLmVhY2hCZWZvcmUoZnVuY3Rpb24obil7
bi5jaGlsZHJlbiYmbi5jaGlsZHJlbi5zb3J0KHQpfSl9LHBhdGg6ZnVuY3Rpb24odCl7Zm9yKHZh
ciBuPXRoaXMsZT1mdW5jdGlvbih0LG4pe2lmKHQ9PT1uKXJldHVybiB0O3ZhciBlPXQuYW5jZXN0
b3JzKCkscj1uLmFuY2VzdG9ycygpLGk9bnVsbDtmb3IodD1lLnBvcCgpLG49ci5wb3AoKTt0PT09
bjspaT10LHQ9ZS5wb3AoKSxuPXIucG9wKCk7cmV0dXJuIGl9KG4sdCkscj1bbl07biE9PWU7KW49
bi5wYXJlbnQsci5wdXNoKG4pO2Zvcih2YXIgaT1yLmxlbmd0aDt0IT09ZTspci5zcGxpY2UoaSww
LHQpLHQ9dC5wYXJlbnQ7cmV0dXJuIHJ9LGFuY2VzdG9yczpmdW5jdGlvbigpe2Zvcih2YXIgdD10
aGlzLG49W3RdO3Q9dC5wYXJlbnQ7KW4ucHVzaCh0KTtyZXR1cm4gbn0sZGVzY2VuZGFudHM6ZnVu
Y3Rpb24oKXt2YXIgdD1bXTtyZXR1cm4gdGhpcy5lYWNoKGZ1bmN0aW9uKG4pe3QucHVzaChuKX0p
LHR9LGxlYXZlczpmdW5jdGlvbigpe3ZhciB0PVtdO3JldHVybiB0aGlzLmVhY2hCZWZvcmUoZnVu
Y3Rpb24obil7bi5jaGlsZHJlbnx8dC5wdXNoKG4pfSksdH0sbGlua3M6ZnVuY3Rpb24oKXt2YXIg
dD10aGlzLG49W107cmV0dXJuIHQuZWFjaChmdW5jdGlvbihlKXtlIT09dCYmbi5wdXNoKHtzb3Vy
Y2U6ZS5wYXJlbnQsdGFyZ2V0OmV9KX0pLG59LGNvcHk6ZnVuY3Rpb24oKXtyZXR1cm4gZm8odGhp
cykuZWFjaEJlZm9yZShobyl9fTt2YXIgV2Q9QXJyYXkucHJvdG90eXBlLnNsaWNlLFpkPSIkIixH
ZD17ZGVwdGg6LTF9LFFkPXt9O0hvLnByb3RvdHlwZT1PYmplY3QuY3JlYXRlKHZvLnByb3RvdHlw
ZSk7dmFyIEpkPSgxK01hdGguc3FydCg1KSkvMixLZD1mdW5jdGlvbiB0KG4pe2Z1bmN0aW9uIGUo
dCxlLHIsaSxvKXtYbyhuLHQsZSxyLGksbyl9cmV0dXJuIGUucmF0aW89ZnVuY3Rpb24obil7cmV0
dXJuIHQoKG49K24pPjE/bjoxKX0sZX0oSmQpLHR2PWZ1bmN0aW9uIHQobil7ZnVuY3Rpb24gZSh0
LGUscixpLG8pe2lmKCh1PXQuX3NxdWFyaWZ5KSYmdS5yYXRpbz09PW4pZm9yKHZhciB1LGEsYyxz
LGYsbD0tMSxoPXUubGVuZ3RoLHA9dC52YWx1ZTsrK2w8aDspe2ZvcihjPShhPXVbbF0pLmNoaWxk
cmVuLHM9YS52YWx1ZT0wLGY9Yy5sZW5ndGg7czxmOysrcylhLnZhbHVlKz1jW3NdLnZhbHVlO2Eu
ZGljZT9xbyhhLGUscixpLHIrPShvLXIpKmEudmFsdWUvcCk6am8oYSxlLHIsZSs9KGktZSkqYS52
YWx1ZS9wLG8pLHAtPWEudmFsdWV9ZWxzZSB0Ll9zcXVhcmlmeT11PVhvKG4sdCxlLHIsaSxvKSx1
LnJhdGlvPW59cmV0dXJuIGUucmF0aW89ZnVuY3Rpb24obil7cmV0dXJuIHQoKG49K24pPjE/bjox
KX0sZX0oSmQpLG52PVtdLnNsaWNlLGV2PXt9O1pvLnByb3RvdHlwZT1Lby5wcm90b3R5cGU9e2Nv
bnN0cnVjdG9yOlpvLGRlZmVyOmZ1bmN0aW9uKHQpe2lmKCJmdW5jdGlvbiIhPXR5cGVvZiB0KXRo
cm93IG5ldyBFcnJvcigiaW52YWxpZCBjYWxsYmFjayIpO2lmKHRoaXMuX2NhbGwpdGhyb3cgbmV3
IEVycm9yKCJkZWZlciBhZnRlciBhd2FpdCIpO2lmKG51bGwhPXRoaXMuX2Vycm9yKXJldHVybiB0
aGlzO3ZhciBuPW52LmNhbGwoYXJndW1lbnRzLDEpO3JldHVybiBuLnB1c2godCksKyt0aGlzLl93
YWl0aW5nLHRoaXMuX3Rhc2tzLnB1c2gobiksR28odGhpcyksdGhpc30sYWJvcnQ6ZnVuY3Rpb24o
KXtyZXR1cm4gbnVsbD09dGhpcy5fZXJyb3ImJlFvKHRoaXMsbmV3IEVycm9yKCJhYm9ydCIpKSx0
aGlzfSxhd2FpdDpmdW5jdGlvbih0KXtpZigiZnVuY3Rpb24iIT10eXBlb2YgdCl0aHJvdyBuZXcg
RXJyb3IoImludmFsaWQgY2FsbGJhY2siKTtpZih0aGlzLl9jYWxsKXRocm93IG5ldyBFcnJvcigi
bXVsdGlwbGUgYXdhaXQiKTtyZXR1cm4gdGhpcy5fY2FsbD1mdW5jdGlvbihuLGUpe3QuYXBwbHko
bnVsbCxbbl0uY29uY2F0KGUpKX0sSm8odGhpcyksdGhpc30sYXdhaXRBbGw6ZnVuY3Rpb24odCl7
aWYoImZ1bmN0aW9uIiE9dHlwZW9mIHQpdGhyb3cgbmV3IEVycm9yKCJpbnZhbGlkIGNhbGxiYWNr
Iik7aWYodGhpcy5fY2FsbCl0aHJvdyBuZXcgRXJyb3IoIm11bHRpcGxlIGF3YWl0Iik7cmV0dXJu
IHRoaXMuX2NhbGw9dCxKbyh0aGlzKSx0aGlzfX07dmFyIHJ2PWZ1bmN0aW9uIHQobil7ZnVuY3Rp
b24gZSh0LGUpe3JldHVybiB0PW51bGw9PXQ/MDordCxlPW51bGw9PWU/MTorZSwxPT09YXJndW1l
bnRzLmxlbmd0aD8oZT10LHQ9MCk6ZS09dCxmdW5jdGlvbigpe3JldHVybiBuKCkqZSt0fX1yZXR1
cm4gZS5zb3VyY2U9dCxlfSh0dSksaXY9ZnVuY3Rpb24gdChuKXtmdW5jdGlvbiBlKHQsZSl7dmFy
IHIsaTtyZXR1cm4gdD1udWxsPT10PzA6K3QsZT1udWxsPT1lPzE6K2UsZnVuY3Rpb24oKXt2YXIg
bztpZihudWxsIT1yKW89cixyPW51bGw7ZWxzZSBkb3tyPTIqbigpLTEsbz0yKm4oKS0xLGk9cipy
K28qb313aGlsZSghaXx8aT4xKTtyZXR1cm4gdCtlKm8qTWF0aC5zcXJ0KC0yKk1hdGgubG9nKGkp
L2kpfX1yZXR1cm4gZS5zb3VyY2U9dCxlfSh0dSksb3Y9ZnVuY3Rpb24gdChuKXtmdW5jdGlvbiBl
KCl7dmFyIHQ9aXYuc291cmNlKG4pLmFwcGx5KHRoaXMsYXJndW1lbnRzKTtyZXR1cm4gZnVuY3Rp
b24oKXtyZXR1cm4gTWF0aC5leHAodCgpKX19cmV0dXJuIGUuc291cmNlPXQsZX0odHUpLHV2PWZ1
bmN0aW9uIHQobil7ZnVuY3Rpb24gZSh0KXtyZXR1cm4gZnVuY3Rpb24oKXtmb3IodmFyIGU9MCxy
PTA7cjx0OysrcillKz1uKCk7cmV0dXJuIGV9fXJldHVybiBlLnNvdXJjZT10LGV9KHR1KSxhdj1m
dW5jdGlvbiB0KG4pe2Z1bmN0aW9uIGUodCl7dmFyIGU9dXYuc291cmNlKG4pKHQpO3JldHVybiBm
dW5jdGlvbigpe3JldHVybiBlKCkvdH19cmV0dXJuIGUuc291cmNlPXQsZX0odHUpLGN2PWZ1bmN0
aW9uIHQobil7ZnVuY3Rpb24gZSh0KXtyZXR1cm4gZnVuY3Rpb24oKXtyZXR1cm4tTWF0aC5sb2co
MS1uKCkpL3R9fXJldHVybiBlLnNvdXJjZT10LGV9KHR1KSxzdj1ldSgidGV4dC9odG1sIixmdW5j
dGlvbih0KXtyZXR1cm4gZG9jdW1lbnQuY3JlYXRlUmFuZ2UoKS5jcmVhdGVDb250ZXh0dWFsRnJh
Z21lbnQodC5yZXNwb25zZVRleHQpfSksZnY9ZXUoImFwcGxpY2F0aW9uL2pzb24iLGZ1bmN0aW9u
KHQpe3JldHVybiBKU09OLnBhcnNlKHQucmVzcG9uc2VUZXh0KX0pLGx2PWV1KCJ0ZXh0L3BsYWlu
IixmdW5jdGlvbih0KXtyZXR1cm4gdC5yZXNwb25zZVRleHR9KSxodj1ldSgiYXBwbGljYXRpb24v
eG1sIixmdW5jdGlvbih0KXt2YXIgbj10LnJlc3BvbnNlWE1MO2lmKCFuKXRocm93IG5ldyBFcnJv
cigicGFyc2UgZXJyb3IiKTtyZXR1cm4gbn0pLHB2PXJ1KCJ0ZXh0L2NzdiIsRWgpLGR2PXJ1KCJ0
ZXh0L3RhYi1zZXBhcmF0ZWQtdmFsdWVzIixSaCksdnY9QXJyYXkucHJvdG90eXBlLGd2PXZ2Lm1h
cCxfdj12di5zbGljZSx5dj17bmFtZToiaW1wbGljaXQifSxtdj1bMCwxXSx4dj1uZXcgRGF0ZSxi
dj1uZXcgRGF0ZSx3dj1DdShmdW5jdGlvbigpe30sZnVuY3Rpb24odCxuKXt0LnNldFRpbWUoK3Qr
bil9LGZ1bmN0aW9uKHQsbil7cmV0dXJuIG4tdH0pO3d2LmV2ZXJ5PWZ1bmN0aW9uKHQpe3JldHVy
biB0PU1hdGguZmxvb3IodCksaXNGaW5pdGUodCkmJnQ+MD90PjE/Q3UoZnVuY3Rpb24obil7bi5z
ZXRUaW1lKE1hdGguZmxvb3Iobi90KSp0KX0sZnVuY3Rpb24obixlKXtuLnNldFRpbWUoK24rZSp0
KX0sZnVuY3Rpb24obixlKXtyZXR1cm4oZS1uKS90fSk6d3Y6bnVsbH07dmFyIE12PXd2LnJhbmdl
LFR2PTZlNCxOdj02MDQ4ZTUsa3Y9Q3UoZnVuY3Rpb24odCl7dC5zZXRUaW1lKDFlMypNYXRoLmZs
b29yKHQvMWUzKSl9LGZ1bmN0aW9uKHQsbil7dC5zZXRUaW1lKCt0KzFlMypuKX0sZnVuY3Rpb24o
dCxuKXtyZXR1cm4obi10KS8xZTN9LGZ1bmN0aW9uKHQpe3JldHVybiB0LmdldFVUQ1NlY29uZHMo
KX0pLFN2PWt2LnJhbmdlLEV2PUN1KGZ1bmN0aW9uKHQpe3Quc2V0VGltZShNYXRoLmZsb29yKHQv
VHYpKlR2KX0sZnVuY3Rpb24odCxuKXt0LnNldFRpbWUoK3QrbipUdil9LGZ1bmN0aW9uKHQsbil7
cmV0dXJuKG4tdCkvVHZ9LGZ1bmN0aW9uKHQpe3JldHVybiB0LmdldE1pbnV0ZXMoKX0pLEF2PUV2
LnJhbmdlLEN2PUN1KGZ1bmN0aW9uKHQpe3ZhciBuPXQuZ2V0VGltZXpvbmVPZmZzZXQoKSpUdiUz
NmU1O248MCYmKG4rPTM2ZTUpLHQuc2V0VGltZSgzNmU1Kk1hdGguZmxvb3IoKCt0LW4pLzM2ZTUp
K24pfSxmdW5jdGlvbih0LG4pe3Quc2V0VGltZSgrdCszNmU1Km4pfSxmdW5jdGlvbih0LG4pe3Jl
dHVybihuLXQpLzM2ZTV9LGZ1bmN0aW9uKHQpe3JldHVybiB0LmdldEhvdXJzKCl9KSx6dj1Ddi5y
YW5nZSxQdj1DdShmdW5jdGlvbih0KXt0LnNldEhvdXJzKDAsMCwwLDApfSxmdW5jdGlvbih0LG4p
e3Quc2V0RGF0ZSh0LmdldERhdGUoKStuKX0sZnVuY3Rpb24odCxuKXtyZXR1cm4obi10LShuLmdl
dFRpbWV6b25lT2Zmc2V0KCktdC5nZXRUaW1lem9uZU9mZnNldCgpKSpUdikvODY0ZTV9LGZ1bmN0
aW9uKHQpe3JldHVybiB0LmdldERhdGUoKS0xfSksUnY9UHYucmFuZ2UsTHY9enUoMCkscXY9enUo
MSksRHY9enUoMiksVXY9enUoMyksT3Y9enUoNCksRnY9enUoNSksSXY9enUoNiksWXY9THYucmFu
Z2UsQnY9cXYucmFuZ2UsSHY9RHYucmFuZ2UsanY9VXYucmFuZ2UsWHY9T3YucmFuZ2UsVnY9RnYu
cmFuZ2UsJHY9SXYucmFuZ2UsV3Y9Q3UoZnVuY3Rpb24odCl7dC5zZXREYXRlKDEpLHQuc2V0SG91
cnMoMCwwLDAsMCl9LGZ1bmN0aW9uKHQsbil7dC5zZXRNb250aCh0LmdldE1vbnRoKCkrbil9LGZ1
bmN0aW9uKHQsbil7cmV0dXJuIG4uZ2V0TW9udGgoKS10LmdldE1vbnRoKCkrMTIqKG4uZ2V0RnVs
bFllYXIoKS10LmdldEZ1bGxZZWFyKCkpfSxmdW5jdGlvbih0KXtyZXR1cm4gdC5nZXRNb250aCgp
fSksWnY9V3YucmFuZ2UsR3Y9Q3UoZnVuY3Rpb24odCl7dC5zZXRNb250aCgwLDEpLHQuc2V0SG91
cnMoMCwwLDAsMCl9LGZ1bmN0aW9uKHQsbil7dC5zZXRGdWxsWWVhcih0LmdldEZ1bGxZZWFyKCkr
bil9LGZ1bmN0aW9uKHQsbil7cmV0dXJuIG4uZ2V0RnVsbFllYXIoKS10LmdldEZ1bGxZZWFyKCl9
LGZ1bmN0aW9uKHQpe3JldHVybiB0LmdldEZ1bGxZZWFyKCl9KTtHdi5ldmVyeT1mdW5jdGlvbih0
KXtyZXR1cm4gaXNGaW5pdGUodD1NYXRoLmZsb29yKHQpKSYmdD4wP0N1KGZ1bmN0aW9uKG4pe24u
c2V0RnVsbFllYXIoTWF0aC5mbG9vcihuLmdldEZ1bGxZZWFyKCkvdCkqdCksbi5zZXRNb250aCgw
LDEpLG4uc2V0SG91cnMoMCwwLDAsMCl9LGZ1bmN0aW9uKG4sZSl7bi5zZXRGdWxsWWVhcihuLmdl
dEZ1bGxZZWFyKCkrZSp0KX0pOm51bGx9O3ZhciBRdj1Hdi5yYW5nZSxKdj1DdShmdW5jdGlvbih0
KXt0LnNldFVUQ1NlY29uZHMoMCwwKX0sZnVuY3Rpb24odCxuKXt0LnNldFRpbWUoK3QrbipUdil9
LGZ1bmN0aW9uKHQsbil7cmV0dXJuKG4tdCkvVHZ9LGZ1bmN0aW9uKHQpe3JldHVybiB0LmdldFVU
Q01pbnV0ZXMoKX0pLEt2PUp2LnJhbmdlLHRnPUN1KGZ1bmN0aW9uKHQpe3Quc2V0VVRDTWludXRl
cygwLDAsMCl9LGZ1bmN0aW9uKHQsbil7dC5zZXRUaW1lKCt0KzM2ZTUqbil9LGZ1bmN0aW9uKHQs
bil7cmV0dXJuKG4tdCkvMzZlNX0sZnVuY3Rpb24odCl7cmV0dXJuIHQuZ2V0VVRDSG91cnMoKX0p
LG5nPXRnLnJhbmdlLGVnPUN1KGZ1bmN0aW9uKHQpe3Quc2V0VVRDSG91cnMoMCwwLDAsMCl9LGZ1
bmN0aW9uKHQsbil7dC5zZXRVVENEYXRlKHQuZ2V0VVRDRGF0ZSgpK24pfSxmdW5jdGlvbih0LG4p
e3JldHVybihuLXQpLzg2NGU1fSxmdW5jdGlvbih0KXtyZXR1cm4gdC5nZXRVVENEYXRlKCktMX0p
LHJnPWVnLnJhbmdlLGlnPVB1KDApLG9nPVB1KDEpLHVnPVB1KDIpLGFnPVB1KDMpLGNnPVB1KDQp
LHNnPVB1KDUpLGZnPVB1KDYpLGxnPWlnLnJhbmdlLGhnPW9nLnJhbmdlLHBnPXVnLnJhbmdlLGRn
PWFnLnJhbmdlLHZnPWNnLnJhbmdlLGdnPXNnLnJhbmdlLF9nPWZnLnJhbmdlLHlnPUN1KGZ1bmN0
aW9uKHQpe3Quc2V0VVRDRGF0ZSgxKSx0LnNldFVUQ0hvdXJzKDAsMCwwLDApfSxmdW5jdGlvbih0
LG4pe3Quc2V0VVRDTW9udGgodC5nZXRVVENNb250aCgpK24pfSxmdW5jdGlvbih0LG4pe3JldHVy
biBuLmdldFVUQ01vbnRoKCktdC5nZXRVVENNb250aCgpKzEyKihuLmdldFVUQ0Z1bGxZZWFyKCkt
dC5nZXRVVENGdWxsWWVhcigpKX0sZnVuY3Rpb24odCl7cmV0dXJuIHQuZ2V0VVRDTW9udGgoKX0p
LG1nPXlnLnJhbmdlLHhnPUN1KGZ1bmN0aW9uKHQpe3Quc2V0VVRDTW9udGgoMCwxKSx0LnNldFVU
Q0hvdXJzKDAsMCwwLDApfSxmdW5jdGlvbih0LG4pe3Quc2V0VVRDRnVsbFllYXIodC5nZXRVVENG
dWxsWWVhcigpK24pfSxmdW5jdGlvbih0LG4pe3JldHVybiBuLmdldFVUQ0Z1bGxZZWFyKCktdC5n
ZXRVVENGdWxsWWVhcigpfSxmdW5jdGlvbih0KXtyZXR1cm4gdC5nZXRVVENGdWxsWWVhcigpfSk7
eGcuZXZlcnk9ZnVuY3Rpb24odCl7cmV0dXJuIGlzRmluaXRlKHQ9TWF0aC5mbG9vcih0KSkmJnQ+
MD9DdShmdW5jdGlvbihuKXtuLnNldFVUQ0Z1bGxZZWFyKE1hdGguZmxvb3Iobi5nZXRVVENGdWxs
WWVhcigpL3QpKnQpLG4uc2V0VVRDTW9udGgoMCwxKSxuLnNldFVUQ0hvdXJzKDAsMCwwLDApfSxm
dW5jdGlvbihuLGUpe24uc2V0VVRDRnVsbFllYXIobi5nZXRVVENGdWxsWWVhcigpK2UqdCl9KTpu
dWxsfTt2YXIgYmcsd2c9eGcucmFuZ2UsTWc9eyItIjoiIixfOiIgIiwwOiIwIn0sVGc9L15ccypc
ZCsvLE5nPS9eJS8sa2c9L1tcXF4kKis/fFtcXSgpLnt9XS9nO0hhKHtkYXRlVGltZToiJXgsICVY
IixkYXRlOiIlLW0vJS1kLyVZIix0aW1lOiIlLUk6JU06JVMgJXAiLHBlcmlvZHM6WyJBTSIsIlBN
Il0sZGF5czpbIlN1bmRheSIsIk1vbmRheSIsIlR1ZXNkYXkiLCJXZWRuZXNkYXkiLCJUaHVyc2Rh
eSIsIkZyaWRheSIsIlNhdHVyZGF5Il0sc2hvcnREYXlzOlsiU3VuIiwiTW9uIiwiVHVlIiwiV2Vk
IiwiVGh1IiwiRnJpIiwiU2F0Il0sbW9udGhzOlsiSmFudWFyeSIsIkZlYnJ1YXJ5IiwiTWFyY2gi
LCJBcHJpbCIsIk1heSIsIkp1bmUiLCJKdWx5IiwiQXVndXN0IiwiU2VwdGVtYmVyIiwiT2N0b2Jl
ciIsIk5vdmVtYmVyIiwiRGVjZW1iZXIiXSxzaG9ydE1vbnRoczpbIkphbiIsIkZlYiIsIk1hciIs
IkFwciIsIk1heSIsIkp1biIsIkp1bCIsIkF1ZyIsIlNlcCIsIk9jdCIsIk5vdiIsIkRlYyJdfSk7
dmFyIFNnPSIlWS0lbS0lZFQlSDolTTolUy4lTFoiLEVnPURhdGUucHJvdG90eXBlLnRvSVNPU3Ry
aW5nP2Z1bmN0aW9uKHQpe3JldHVybiB0LnRvSVNPU3RyaW5nKCl9OnQudXRjRm9ybWF0KFNnKSxB
Zz0rbmV3IERhdGUoIjIwMDAtMDEtMDFUMDA6MDA6MDAuMDAwWiIpP2Z1bmN0aW9uKHQpe3ZhciBu
PW5ldyBEYXRlKHQpO3JldHVybiBpc05hTihuKT9udWxsOm59OnQudXRjUGFyc2UoU2cpLENnPTFl
Myx6Zz02MCpDZyxQZz02MCp6ZyxSZz0yNCpQZyxMZz03KlJnLHFnPTMwKlJnLERnPTM2NSpSZyxV
Zz0kYSgiMWY3N2I0ZmY3ZjBlMmNhMDJjZDYyNzI4OTQ2N2JkOGM1NjRiZTM3N2MyN2Y3ZjdmYmNi
ZDIyMTdiZWNmIiksT2c9JGEoIjM5M2I3OTUyNTRhMzZiNmVjZjljOWVkZTYzNzkzOThjYTI1MmI1
Y2Y2YmNlZGI5YzhjNmQzMWJkOWUzOWU3YmE1MmU3Y2I5NDg0M2MzOWFkNDk0YWQ2NjE2YmU3OTY5
YzdiNDE3M2E1NTE5NGNlNmRiZGRlOWVkNiIpLEZnPSRhKCIzMTgyYmQ2YmFlZDY5ZWNhZTFjNmRi
ZWZlNjU1MGRmZDhkM2NmZGFlNmJmZGQwYTIzMWEzNTQ3NGM0NzZhMWQ5OWJjN2U5YzA3NTZiYjE5
ZTlhYzhiY2JkZGNkYWRhZWI2MzYzNjM5Njk2OTZiZGJkYmRkOWQ5ZDkiKSxJZz0kYSgiMWY3N2I0
YWVjN2U4ZmY3ZjBlZmZiYjc4MmNhMDJjOThkZjhhZDYyNzI4ZmY5ODk2OTQ2N2JkYzViMGQ1OGM1
NjRiYzQ5Yzk0ZTM3N2MyZjdiNmQyN2Y3ZjdmYzdjN2M3YmNiZDIyZGJkYjhkMTdiZWNmOWVkYWU1
IiksWWc9YWwoJHQoMzAwLC41LDApLCR0KC0yNDAsLjUsMSkpLEJnPWFsKCR0KC0xMDAsLjc1LC4z
NSksJHQoODAsMS41LC44KSksSGc9YWwoJHQoMjYwLC43NSwuMzUpLCR0KDgwLDEuNSwuOCkpLGpn
PSR0KCksWGc9V2EoJGEoIjQ0MDE1NDQ0MDI1NjQ1MDQ1NzQ1MDU1OTQ2MDc1YTQ2MDg1YzQ2MGE1
ZDQ2MGI1ZTQ3MGQ2MDQ3MGU2MTQ3MTA2MzQ3MTE2NDQ3MTM2NTQ4MTQ2NzQ4MTY2ODQ4MTc2OTQ4
MTg2YTQ4MWE2YzQ4MWI2ZDQ4MWM2ZTQ4MWQ2ZjQ4MWY3MDQ4MjA3MTQ4MjE3MzQ4MjM3NDQ4MjQ3
NTQ4MjU3NjQ4MjY3NzQ4Mjg3ODQ4Mjk3OTQ3MmE3YTQ3MmM3YTQ3MmQ3YjQ3MmU3YzQ3MmY3ZDQ2
MzA3ZTQ2MzI3ZTQ2MzM3ZjQ2MzQ4MDQ1MzU4MTQ1Mzc4MTQ1Mzg4MjQ0Mzk4MzQ0M2E4MzQ0M2I4
NDQzM2Q4NDQzM2U4NTQyM2Y4NTQyNDA4NjQyNDE4NjQxNDI4NzQxNDQ4NzQwNDU4ODQwNDY4ODNm
NDc4ODNmNDg4OTNlNDk4OTNlNGE4OTNlNGM4YTNkNGQ4YTNkNGU4YTNjNGY4YTNjNTA4YjNiNTE4
YjNiNTI4YjNhNTM4YjNhNTQ4YzM5NTU4YzM5NTY4YzM4NTg4YzM4NTk4YzM3NWE4YzM3NWI4ZDM2
NWM4ZDM2NWQ4ZDM1NWU4ZDM1NWY4ZDM0NjA4ZDM0NjE4ZDMzNjI4ZDMzNjM4ZDMyNjQ4ZTMyNjU4
ZTMxNjY4ZTMxNjc4ZTMxNjg4ZTMwNjk4ZTMwNmE4ZTJmNmI4ZTJmNmM4ZTJlNmQ4ZTJlNmU4ZTJl
NmY4ZTJkNzA4ZTJkNzE4ZTJjNzE4ZTJjNzI4ZTJjNzM4ZTJiNzQ4ZTJiNzU4ZTJhNzY4ZTJhNzc4
ZTJhNzg4ZTI5Nzk4ZTI5N2E4ZTI5N2I4ZTI4N2M4ZTI4N2Q4ZTI3N2U4ZTI3N2Y4ZTI3ODA4ZTI2
ODE4ZTI2ODI4ZTI2ODI4ZTI1ODM4ZTI1ODQ4ZTI1ODU4ZTI0ODY4ZTI0ODc4ZTIzODg4ZTIzODk4
ZTIzOGE4ZDIyOGI4ZDIyOGM4ZDIyOGQ4ZDIxOGU4ZDIxOGY4ZDIxOTA4ZDIxOTE4YzIwOTI4YzIw
OTI4YzIwOTM4YzFmOTQ4YzFmOTU4YjFmOTY4YjFmOTc4YjFmOTg4YjFmOTk4YTFmOWE4YTFlOWI4
YTFlOWM4OTFlOWQ4OTFmOWU4OTFmOWY4ODFmYTA4ODFmYTE4ODFmYTE4NzFmYTI4NzIwYTM4NjIw
YTQ4NjIxYTU4NTIxYTY4NTIyYTc4NTIyYTg4NDIzYTk4MzI0YWE4MzI1YWI4MjI1YWM4MjI2YWQ4
MTI3YWQ4MTI4YWU4MDI5YWY3ZjJhYjA3ZjJjYjE3ZTJkYjI3ZDJlYjM3YzJmYjQ3YzMxYjU3YjMy
YjY3YTM0YjY3OTM1Yjc3OTM3Yjg3ODM4Yjk3NzNhYmE3NjNiYmI3NTNkYmM3NDNmYmM3MzQwYmQ3
MjQyYmU3MTQ0YmY3MDQ2YzA2ZjQ4YzE2ZTRhYzE2ZDRjYzI2YzRlYzM2YjUwYzQ2YTUyYzU2OTU0
YzU2ODU2YzY2NzU4Yzc2NTVhYzg2NDVjYzg2MzVlYzk2MjYwY2E2MDYzY2I1ZjY1Y2I1ZTY3Y2M1
YzY5Y2Q1YjZjY2Q1YTZlY2U1ODcwY2Y1NzczZDA1Njc1ZDA1NDc3ZDE1MzdhZDE1MTdjZDI1MDdm
ZDM0ZTgxZDM0ZDg0ZDQ0Yjg2ZDU0OTg5ZDU0ODhiZDY0NjhlZDY0NTkwZDc0MzkzZDc0MTk1ZDg0
MDk4ZDgzZTliZDkzYzlkZDkzYmEwZGEzOWEyZGEzN2E1ZGIzNmE4ZGIzNGFhZGMzMmFkZGMzMGIw
ZGQyZmIyZGQyZGI1ZGUyYmI4ZGUyOWJhZGUyOGJkZGYyNmMwZGYyNWMyZGYyM2M1ZTAyMWM4ZTAy
MGNhZTExZmNkZTExZGQwZTExY2QyZTIxYmQ1ZTIxYWQ4ZTIxOWRhZTMxOWRkZTMxOGRmZTMxOGUy
ZTQxOGU1ZTQxOWU3ZTQxOWVhZTUxYWVjZTUxYmVmZTUxY2YxZTUxZGY0ZTYxZWY2ZTYyMGY4ZTYy
MWZiZTcyM2ZkZTcyNSIpKSxWZz1XYSgkYSgiMDAwMDA0MDEwMDA1MDEwMTA2MDEwMTA4MDIwMTA5
MDIwMjBiMDIwMjBkMDMwMzBmMDMwMzEyMDQwNDE0MDUwNDE2MDYwNTE4MDYwNTFhMDcwNjFjMDgw
NzFlMDkwNzIwMGEwODIyMGIwOTI0MGMwOTI2MGQwYTI5MGUwYjJiMTAwYjJkMTEwYzJmMTIwZDMx
MTMwZDM0MTQwZTM2MTUwZTM4MTYwZjNiMTgwZjNkMTkxMDNmMWExMDQyMWMxMDQ0MWQxMTQ3MWUx
MTQ5MjAxMTRiMjExMTRlMjIxMTUwMjQxMjUzMjUxMjU1MjcxMjU4MjkxMTVhMmExMTVjMmMxMTVm
MmQxMTYxMmYxMTYzMzExMTY1MzMxMDY3MzQxMDY5MzYxMDZiMzgxMDZjMzkwZjZlM2IwZjcwM2Qw
ZjcxM2YwZjcyNDAwZjc0NDIwZjc1NDQwZjc2NDUxMDc3NDcxMDc4NDkxMDc4NGExMDc5NGMxMTdh
NGUxMTdiNGYxMjdiNTExMjdjNTIxMzdjNTQxMzdkNTYxNDdkNTcxNTdlNTkxNTdlNWExNjdlNWMx
NjdmNWQxNzdmNWYxODdmNjAxODgwNjIxOTgwNjQxYTgwNjUxYTgwNjcxYjgwNjgxYzgxNmExYzgx
NmIxZDgxNmQxZDgxNmUxZTgxNzAxZjgxNzIxZjgxNzMyMDgxNzUyMTgxNzYyMTgxNzgyMjgxNzky
MjgyN2IyMzgyN2MyMzgyN2UyNDgyODAyNTgyODEyNTgxODMyNjgxODQyNjgxODYyNzgxODgyNzgx
ODkyODgxOGIyOTgxOGMyOTgxOGUyYTgxOTAyYTgxOTEyYjgxOTMyYjgwOTQyYzgwOTYyYzgwOTgy
ZDgwOTkyZDgwOWIyZTdmOWMyZTdmOWUyZjdmYTAyZjdmYTEzMDdlYTMzMDdlYTUzMTdlYTYzMTdk
YTgzMjdkYWEzMzdkYWIzMzdjYWQzNDdjYWUzNDdiYjAzNTdiYjIzNTdiYjMzNjdhYjUzNjdhYjcz
Nzc5YjgzNzc5YmEzODc4YmMzOTc4YmQzOTc3YmYzYTc3YzAzYTc2YzIzYjc1YzQzYzc1YzUzYzc0
YzczZDczYzgzZTczY2EzZTcyY2MzZjcxY2Q0MDcxY2Y0MDcwZDA0MTZmZDI0MjZmZDM0MzZlZDU0
NDZkZDY0NTZjZDg0NTZjZDk0NjZiZGI0NzZhZGM0ODY5ZGU0OTY4ZGY0YTY4ZTA0YzY3ZTI0ZDY2
ZTM0ZTY1ZTQ0ZjY0ZTU1MDY0ZTc1MjYzZTg1MzYyZTk1NDYyZWE1NjYxZWI1NzYwZWM1ODYwZWQ1
YTVmZWU1YjVlZWY1ZDVlZjA1ZjVlZjE2MDVkZjI2MjVkZjI2NDVjZjM2NTVjZjQ2NzVjZjQ2OTVj
ZjU2YjVjZjY2YzVjZjY2ZTVjZjc3MDVjZjc3MjVjZjg3NDVjZjg3NjVjZjk3ODVkZjk3OTVkZjk3
YjVkZmE3ZDVlZmE3ZjVlZmE4MTVmZmI4MzVmZmI4NTYwZmI4NzYxZmM4OTYxZmM4YTYyZmM4YzYz
ZmM4ZTY0ZmM5MDY1ZmQ5MjY2ZmQ5NDY3ZmQ5NjY4ZmQ5ODY5ZmQ5YTZhZmQ5YjZiZmU5ZDZjZmU5
ZjZkZmVhMTZlZmVhMzZmZmVhNTcxZmVhNzcyZmVhOTczZmVhYTc0ZmVhYzc2ZmVhZTc3ZmViMDc4
ZmViMjdhZmViNDdiZmViNjdjZmViNzdlZmViOTdmZmViYjgxZmViZDgyZmViZjg0ZmVjMTg1ZmVj
Mjg3ZmVjNDg4ZmVjNjhhZmVjODhjZmVjYThkZmVjYzhmZmVjZDkwZmVjZjkyZmVkMTk0ZmVkMzk1
ZmVkNTk3ZmVkNzk5ZmVkODlhZmRkYTljZmRkYzllZmRkZWEwZmRlMGExZmRlMmEzZmRlM2E1ZmRl
NWE3ZmRlN2E5ZmRlOWFhZmRlYmFjZmNlY2FlZmNlZWIwZmNmMGIyZmNmMmI0ZmNmNGI2ZmNmNmI4
ZmNmN2I5ZmNmOWJiZmNmYmJkZmNmZGJmIikpLCRnPVdhKCRhKCIwMDAwMDQwMTAwMDUwMTAxMDYw
MTAxMDgwMjAxMGEwMjAyMGMwMjAyMGUwMzAyMTAwNDAzMTIwNDAzMTQwNTA0MTcwNjA0MTkwNzA1
MWIwODA1MWQwOTA2MWYwYTA3MjIwYjA3MjQwYzA4MjYwZDA4MjkwZTA5MmIxMDA5MmQxMTBhMzAx
MjBhMzIxNDBiMzQxNTBiMzcxNjBiMzkxODBjM2MxOTBjM2UxYjBjNDExYzBjNDMxZTBjNDUxZjBj
NDgyMTBjNGEyMzBjNGMyNDBjNGYyNjBjNTEyODBiNTMyOTBiNTUyYjBiNTcyZDBiNTkyZjBhNWIz
MTBhNWMzMjBhNWUzNDBhNWYzNjA5NjEzODA5NjIzOTA5NjMzYjA5NjQzZDA5NjUzZTA5NjY0MDBh
Njc0MjBhNjg0NDBhNjg0NTBhNjk0NzBiNmE0OTBiNmE0YTBjNmI0YzBjNmI0ZDBkNmM0ZjBkNmM1
MTBlNmM1MjBlNmQ1NDBmNmQ1NTBmNmQ1NzEwNmU1OTEwNmU1YTExNmU1YzEyNmU1ZDEyNmU1ZjEz
NmU2MTEzNmU2MjE0NmU2NDE1NmU2NTE1NmU2NzE2NmU2OTE2NmU2YTE3NmU2YzE4NmU2ZDE4NmU2
ZjE5NmU3MTE5NmU3MjFhNmU3NDFhNmU3NTFiNmU3NzFjNmQ3ODFjNmQ3YTFkNmQ3YzFkNmQ3ZDFl
NmQ3ZjFlNmM4MDFmNmM4MjIwNmM4NDIwNmI4NTIxNmI4NzIxNmI4ODIyNmE4YTIyNmE4YzIzNjk4
ZDIzNjk4ZjI0Njk5MDI1Njg5MjI1Njg5MzI2Njc5NTI2Njc5NzI3NjY5ODI3NjY5YTI4NjU5YjI5
NjQ5ZDI5NjQ5ZjJhNjNhMDJhNjNhMjJiNjJhMzJjNjFhNTJjNjBhNjJkNjBhODJlNWZhOTJlNWVh
YjJmNWVhZDMwNWRhZTMwNWNiMDMxNWJiMTMyNWFiMzMyNWFiNDMzNTliNjM0NThiNzM1NTdiOTM1
NTZiYTM2NTViYzM3NTRiZDM4NTNiZjM5NTJjMDNhNTFjMTNhNTBjMzNiNGZjNDNjNGVjNjNkNGRj
NzNlNGNjODNmNGJjYTQwNGFjYjQxNDljYzQyNDhjZTQzNDdjZjQ0NDZkMDQ1NDVkMjQ2NDRkMzQ3
NDNkNDQ4NDJkNTRhNDFkNzRiM2ZkODRjM2VkOTRkM2RkYTRlM2NkYjUwM2JkZDUxM2FkZTUyMzhk
ZjUzMzdlMDU1MzZlMTU2MzVlMjU3MzRlMzU5MzNlNDVhMzFlNTVjMzBlNjVkMmZlNzVlMmVlODYw
MmRlOTYxMmJlYTYzMmFlYjY0MjllYjY2MjhlYzY3MjZlZDY5MjVlZTZhMjRlZjZjMjNlZjZlMjFm
MDZmMjBmMTcxMWZmMTczMWRmMjc0MWNmMzc2MWJmMzc4MTlmNDc5MThmNTdiMTdmNTdkMTVmNjdl
MTRmNjgwMTNmNzgyMTJmNzg0MTBmODg1MGZmODg3MGVmODg5MGNmOThiMGJmOThjMGFmOThlMDlm
YTkwMDhmYTkyMDdmYTk0MDdmYjk2MDZmYjk3MDZmYjk5MDZmYjliMDZmYjlkMDdmYzlmMDdmY2Ex
MDhmY2EzMDlmY2E1MGFmY2E2MGNmY2E4MGRmY2FhMGZmY2FjMTFmY2FlMTJmY2IwMTRmY2IyMTZm
Y2I0MThmYmI2MWFmYmI4MWRmYmJhMWZmYmJjMjFmYmJlMjNmYWMwMjZmYWMyMjhmYWM0MmFmYWM2
MmRmOWM3MmZmOWM5MzJmOWNiMzVmOGNkMzdmOGNmM2FmN2QxM2RmN2QzNDBmNmQ1NDNmNmQ3NDZm
NWQ5NDlmNWRiNGNmNGRkNGZmNGRmNTNmNGUxNTZmM2UzNWFmM2U1NWRmMmU2NjFmMmU4NjVmMmVh
NjlmMWVjNmRmMWVkNzFmMWVmNzVmMWYxNzlmMmYyN2RmMmY0ODJmM2Y1ODZmM2Y2OGFmNGY4OGVm
NWY5OTJmNmZhOTZmOGZiOWFmOWZjOWRmYWZkYTFmY2ZmYTQiKSksV2c9V2EoJGEoIjBkMDg4NzEw
MDc4ODEzMDc4OTE2MDc4YTE5MDY4YzFiMDY4ZDFkMDY4ZTIwMDY4ZjIyMDY5MDI0MDY5MTI2MDU5
MTI4MDU5MjJhMDU5MzJjMDU5NDJlMDU5NTJmMDU5NjMxMDU5NzMzMDU5NzM1MDQ5ODM3MDQ5OTM4
MDQ5YTNhMDQ5YTNjMDQ5YjNlMDQ5YzNmMDQ5YzQxMDQ5ZDQzMDM5ZTQ0MDM5ZTQ2MDM5ZjQ4MDM5
ZjQ5MDNhMDRiMDNhMTRjMDJhMTRlMDJhMjUwMDJhMjUxMDJhMzUzMDJhMzU1MDJhNDU2MDFhNDU4
MDFhNDU5MDFhNTViMDFhNTVjMDFhNjVlMDFhNjYwMDFhNjYxMDBhNzYzMDBhNzY0MDBhNzY2MDBh
NzY3MDBhODY5MDBhODZhMDBhODZjMDBhODZlMDBhODZmMDBhODcxMDBhODcyMDFhODc0MDFhODc1
MDFhODc3MDFhODc4MDFhODdhMDJhODdiMDJhODdkMDNhODdlMDNhODgwMDRhODgxMDRhNzgzMDVh
Nzg0MDVhNzg2MDZhNjg3MDdhNjg4MDhhNjhhMDlhNThiMGFhNThkMGJhNThlMGNhNDhmMGRhNDkx
MGVhMzkyMGZhMzk0MTBhMjk1MTFhMTk2MTNhMTk4MTRhMDk5MTU5ZjlhMTY5ZjljMTc5ZTlkMTg5
ZDllMTk5ZGEwMWE5Y2ExMWI5YmEyMWQ5YWEzMWU5YWE1MWY5OWE2MjA5OGE3MjE5N2E4MjI5NmFh
MjM5NWFiMjQ5NGFjMjY5NGFkMjc5M2FlMjg5MmIwMjk5MWIxMmE5MGIyMmI4ZmIzMmM4ZWI0MmU4
ZGI1MmY4Y2I2MzA4YmI3MzE4YWI4MzI4OWJhMzM4OGJiMzQ4OGJjMzU4N2JkMzc4NmJlMzg4NWJm
Mzk4NGMwM2E4M2MxM2I4MmMyM2M4MWMzM2Q4MGM0M2U3ZmM1NDA3ZWM2NDE3ZGM3NDI3Y2M4NDM3
YmM5NDQ3YWNhNDU3YWNiNDY3OWNjNDc3OGNjNDk3N2NkNGE3NmNlNGI3NWNmNGM3NGQwNGQ3M2Qx
NGU3MmQyNGY3MWQzNTE3MWQ0NTI3MGQ1NTM2ZmQ1NTQ2ZWQ2NTU2ZGQ3NTY2Y2Q4NTc2YmQ5NTg2
YWRhNWE2YWRhNWI2OWRiNWM2OGRjNWQ2N2RkNWU2NmRlNWY2NWRlNjE2NGRmNjI2M2UwNjM2M2Ux
NjQ2MmUyNjU2MWUyNjY2MGUzNjg1ZmU0Njk1ZWU1NmE1ZGU1NmI1ZGU2NmM1Y2U3NmU1YmU3NmY1
YWU4NzA1OWU5NzE1OGU5NzI1N2VhNzQ1N2ViNzU1NmViNzY1NWVjNzc1NGVkNzk1M2VkN2E1MmVl
N2I1MWVmN2M1MWVmN2U1MGYwN2Y0ZmYwODA0ZWYxODE0ZGYxODM0Y2YyODQ0YmYzODU0YmYzODc0
YWY0ODg0OWY0ODk0OGY1OGI0N2Y1OGM0NmY2OGQ0NWY2OGY0NGY3OTA0NGY3OTE0M2Y3OTM0MmY4
OTQ0MWY4OTU0MGY5OTczZmY5OTgzZWY5OWEzZWZhOWIzZGZhOWMzY2ZhOWUzYmZiOWYzYWZiYTEz
OWZiYTIzOGZjYTMzOGZjYTUzN2ZjYTYzNmZjYTgzNWZjYTkzNGZkYWIzM2ZkYWMzM2ZkYWUzMmZk
YWYzMWZkYjEzMGZkYjIyZmZkYjQyZmZkYjUyZWZlYjcyZGZlYjgyY2ZlYmEyY2ZlYmIyYmZlYmQy
YWZlYmUyYWZlYzAyOWZkYzIyOWZkYzMyOGZkYzUyN2ZkYzYyN2ZkYzgyN2ZkY2EyNmZkY2IyNmZj
Y2QyNWZjY2UyNWZjZDAyNWZjZDIyNWZiZDMyNGZiZDUyNGZiZDcyNGZhZDgyNGZhZGEyNGY5ZGMy
NGY5ZGQyNWY4ZGYyNWY4ZTEyNWY3ZTIyNWY3ZTQyNWY2ZTYyNmY2ZTgyNmY1ZTkyNmY1ZWIyN2Y0
ZWQyN2YzZWUyN2YzZjAyN2YyZjIyN2YxZjQyNmYxZjUyNWYwZjcyNGYwZjkyMSIpKSxaZz1NYXRo
LmFicyxHZz1NYXRoLmF0YW4yLFFnPU1hdGguY29zLEpnPU1hdGgubWF4LEtnPU1hdGgubWluLHRf
PU1hdGguc2luLG5fPU1hdGguc3FydCxlXz0xZS0xMixyXz1NYXRoLlBJLGlfPXJfLzIsb189Mipy
XztpYy5wcm90b3R5cGU9e2FyZWFTdGFydDpmdW5jdGlvbigpe3RoaXMuX2xpbmU9MH0sYXJlYUVu
ZDpmdW5jdGlvbigpe3RoaXMuX2xpbmU9TmFOfSxsaW5lU3RhcnQ6ZnVuY3Rpb24oKXt0aGlzLl9w
b2ludD0wfSxsaW5lRW5kOmZ1bmN0aW9uKCl7KHRoaXMuX2xpbmV8fDAhPT10aGlzLl9saW5lJiYx
PT09dGhpcy5fcG9pbnQpJiZ0aGlzLl9jb250ZXh0LmNsb3NlUGF0aCgpLHRoaXMuX2xpbmU9MS10
aGlzLl9saW5lfSxwb2ludDpmdW5jdGlvbih0LG4pe3N3aXRjaCh0PSt0LG49K24sdGhpcy5fcG9p
bnQpe2Nhc2UgMDp0aGlzLl9wb2ludD0xLHRoaXMuX2xpbmU/dGhpcy5fY29udGV4dC5saW5lVG8o
dCxuKTp0aGlzLl9jb250ZXh0Lm1vdmVUbyh0LG4pO2JyZWFrO2Nhc2UgMTp0aGlzLl9wb2ludD0y
O2RlZmF1bHQ6dGhpcy5fY29udGV4dC5saW5lVG8odCxuKX19fTt2YXIgdV89cGMob2MpO2hjLnBy
b3RvdHlwZT17YXJlYVN0YXJ0OmZ1bmN0aW9uKCl7dGhpcy5fY3VydmUuYXJlYVN0YXJ0KCl9LGFy
ZWFFbmQ6ZnVuY3Rpb24oKXt0aGlzLl9jdXJ2ZS5hcmVhRW5kKCl9LGxpbmVTdGFydDpmdW5jdGlv
bigpe3RoaXMuX2N1cnZlLmxpbmVTdGFydCgpfSxsaW5lRW5kOmZ1bmN0aW9uKCl7dGhpcy5fY3Vy
dmUubGluZUVuZCgpfSxwb2ludDpmdW5jdGlvbih0LG4pe3RoaXMuX2N1cnZlLnBvaW50KG4qTWF0
aC5zaW4odCksbiotTWF0aC5jb3ModCkpfX07dmFyIGFfPUFycmF5LnByb3RvdHlwZS5zbGljZSxj
Xz17ZHJhdzpmdW5jdGlvbih0LG4pe3ZhciBlPU1hdGguc3FydChuL3JfKTt0Lm1vdmVUbyhlLDAp
LHQuYXJjKDAsMCxlLDAsb18pfX0sc189e2RyYXc6ZnVuY3Rpb24odCxuKXt2YXIgZT1NYXRoLnNx
cnQobi81KS8yO3QubW92ZVRvKC0zKmUsLWUpLHQubGluZVRvKC1lLC1lKSx0LmxpbmVUbygtZSwt
MyplKSx0LmxpbmVUbyhlLC0zKmUpLHQubGluZVRvKGUsLWUpLHQubGluZVRvKDMqZSwtZSksdC5s
aW5lVG8oMyplLGUpLHQubGluZVRvKGUsZSksdC5saW5lVG8oZSwzKmUpLHQubGluZVRvKC1lLDMq
ZSksdC5saW5lVG8oLWUsZSksdC5saW5lVG8oLTMqZSxlKSx0LmNsb3NlUGF0aCgpfX0sZl89TWF0
aC5zcXJ0KDEvMyksbF89MipmXyxoXz17ZHJhdzpmdW5jdGlvbih0LG4pe3ZhciBlPU1hdGguc3Fy
dChuL2xfKSxyPWUqZl87dC5tb3ZlVG8oMCwtZSksdC5saW5lVG8ociwwKSx0LmxpbmVUbygwLGUp
LHQubGluZVRvKC1yLDApLHQuY2xvc2VQYXRoKCl9fSxwXz1NYXRoLnNpbihyXy8xMCkvTWF0aC5z
aW4oNypyXy8xMCksZF89TWF0aC5zaW4ob18vMTApKnBfLHZfPS1NYXRoLmNvcyhvXy8xMCkqcF8s
Z189e2RyYXc6ZnVuY3Rpb24odCxuKXt2YXIgZT1NYXRoLnNxcnQoLjg5MDgxMzA5MTUyOTI4NTIq
bikscj1kXyplLGk9dl8qZTt0Lm1vdmVUbygwLC1lKSx0LmxpbmVUbyhyLGkpO2Zvcih2YXIgbz0x
O288NTsrK28pe3ZhciB1PW9fKm8vNSxhPU1hdGguY29zKHUpLGM9TWF0aC5zaW4odSk7dC5saW5l
VG8oYyplLC1hKmUpLHQubGluZVRvKGEqci1jKmksYypyK2EqaSl9dC5jbG9zZVBhdGgoKX19LF9f
PXtkcmF3OmZ1bmN0aW9uKHQsbil7dmFyIGU9TWF0aC5zcXJ0KG4pLHI9LWUvMjt0LnJlY3Qocixy
LGUsZSl9fSx5Xz1NYXRoLnNxcnQoMyksbV89e2RyYXc6ZnVuY3Rpb24odCxuKXt2YXIgZT0tTWF0
aC5zcXJ0KG4vKDMqeV8pKTt0Lm1vdmVUbygwLDIqZSksdC5saW5lVG8oLXlfKmUsLWUpLHQubGlu
ZVRvKHlfKmUsLWUpLHQuY2xvc2VQYXRoKCl9fSx4Xz1NYXRoLnNxcnQoMykvMixiXz0xL01hdGgu
c3FydCgxMiksd189MyooYl8vMisxKSxNXz17ZHJhdzpmdW5jdGlvbih0LG4pe3ZhciBlPU1hdGgu
c3FydChuL3dfKSxyPWUvMixpPWUqYl8sbz1yLHU9ZSpiXytlLGE9LW8sYz11O3QubW92ZVRvKHIs
aSksdC5saW5lVG8obyx1KSx0LmxpbmVUbyhhLGMpLHQubGluZVRvKC0uNSpyLXhfKmkseF8qcist
LjUqaSksdC5saW5lVG8oLS41Km8teF8qdSx4XypvKy0uNSp1KSx0LmxpbmVUbygtLjUqYS14Xypj
LHhfKmErLS41KmMpLHQubGluZVRvKC0uNSpyK3hfKmksLS41KmkteF8qciksdC5saW5lVG8oLS41
Km8reF8qdSwtLjUqdS14XypvKSx0LmxpbmVUbygtLjUqYSt4XypjLC0uNSpjLXhfKmEpLHQuY2xv
c2VQYXRoKCl9fSxUXz1bY18sc18saF8sX18sZ18sbV8sTV9dO2tjLnByb3RvdHlwZT17YXJlYVN0
YXJ0OmZ1bmN0aW9uKCl7dGhpcy5fbGluZT0wfSxhcmVhRW5kOmZ1bmN0aW9uKCl7dGhpcy5fbGlu
ZT1OYU59LGxpbmVTdGFydDpmdW5jdGlvbigpe3RoaXMuX3gwPXRoaXMuX3gxPXRoaXMuX3kwPXRo
aXMuX3kxPU5hTix0aGlzLl9wb2ludD0wfSxsaW5lRW5kOmZ1bmN0aW9uKCl7c3dpdGNoKHRoaXMu
X3BvaW50KXtjYXNlIDM6TmModGhpcyx0aGlzLl94MSx0aGlzLl95MSk7Y2FzZSAyOnRoaXMuX2Nv
bnRleHQubGluZVRvKHRoaXMuX3gxLHRoaXMuX3kxKX0odGhpcy5fbGluZXx8MCE9PXRoaXMuX2xp
bmUmJjE9PT10aGlzLl9wb2ludCkmJnRoaXMuX2NvbnRleHQuY2xvc2VQYXRoKCksdGhpcy5fbGlu
ZT0xLXRoaXMuX2xpbmV9LHBvaW50OmZ1bmN0aW9uKHQsbil7c3dpdGNoKHQ9K3Qsbj0rbix0aGlz
Ll9wb2ludCl7Y2FzZSAwOnRoaXMuX3BvaW50PTEsdGhpcy5fbGluZT90aGlzLl9jb250ZXh0Lmxp
bmVUbyh0LG4pOnRoaXMuX2NvbnRleHQubW92ZVRvKHQsbik7YnJlYWs7Y2FzZSAxOnRoaXMuX3Bv
aW50PTI7YnJlYWs7Y2FzZSAyOnRoaXMuX3BvaW50PTMsdGhpcy5fY29udGV4dC5saW5lVG8oKDUq
dGhpcy5feDArdGhpcy5feDEpLzYsKDUqdGhpcy5feTArdGhpcy5feTEpLzYpO2RlZmF1bHQ6TmMo
dGhpcyx0LG4pfXRoaXMuX3gwPXRoaXMuX3gxLHRoaXMuX3gxPXQsdGhpcy5feTA9dGhpcy5feTEs
dGhpcy5feTE9bn19LFNjLnByb3RvdHlwZT17YXJlYVN0YXJ0OlRjLGFyZWFFbmQ6VGMsbGluZVN0
YXJ0OmZ1bmN0aW9uKCl7dGhpcy5feDA9dGhpcy5feDE9dGhpcy5feDI9dGhpcy5feDM9dGhpcy5f
eDQ9dGhpcy5feTA9dGhpcy5feTE9dGhpcy5feTI9dGhpcy5feTM9dGhpcy5feTQ9TmFOLHRoaXMu
X3BvaW50PTB9LGxpbmVFbmQ6ZnVuY3Rpb24oKXtzd2l0Y2godGhpcy5fcG9pbnQpe2Nhc2UgMTp0
aGlzLl9jb250ZXh0Lm1vdmVUbyh0aGlzLl94Mix0aGlzLl95MiksdGhpcy5fY29udGV4dC5jbG9z
ZVBhdGgoKTticmVhaztjYXNlIDI6dGhpcy5fY29udGV4dC5tb3ZlVG8oKHRoaXMuX3gyKzIqdGhp
cy5feDMpLzMsKHRoaXMuX3kyKzIqdGhpcy5feTMpLzMpLHRoaXMuX2NvbnRleHQubGluZVRvKCh0
aGlzLl94MysyKnRoaXMuX3gyKS8zLCh0aGlzLl95MysyKnRoaXMuX3kyKS8zKSx0aGlzLl9jb250
ZXh0LmNsb3NlUGF0aCgpO2JyZWFrO2Nhc2UgMzp0aGlzLnBvaW50KHRoaXMuX3gyLHRoaXMuX3ky
KSx0aGlzLnBvaW50KHRoaXMuX3gzLHRoaXMuX3kzKSx0aGlzLnBvaW50KHRoaXMuX3g0LHRoaXMu
X3k0KX19LHBvaW50OmZ1bmN0aW9uKHQsbil7c3dpdGNoKHQ9K3Qsbj0rbix0aGlzLl9wb2ludCl7
Y2FzZSAwOnRoaXMuX3BvaW50PTEsdGhpcy5feDI9dCx0aGlzLl95Mj1uO2JyZWFrO2Nhc2UgMTp0
aGlzLl9wb2ludD0yLHRoaXMuX3gzPXQsdGhpcy5feTM9bjticmVhaztjYXNlIDI6dGhpcy5fcG9p
bnQ9Myx0aGlzLl94ND10LHRoaXMuX3k0PW4sdGhpcy5fY29udGV4dC5tb3ZlVG8oKHRoaXMuX3gw
KzQqdGhpcy5feDErdCkvNiwodGhpcy5feTArNCp0aGlzLl95MStuKS82KTticmVhaztkZWZhdWx0
Ok5jKHRoaXMsdCxuKX10aGlzLl94MD10aGlzLl94MSx0aGlzLl94MT10LHRoaXMuX3kwPXRoaXMu
X3kxLHRoaXMuX3kxPW59fSxFYy5wcm90b3R5cGU9e2FyZWFTdGFydDpmdW5jdGlvbigpe3RoaXMu
X2xpbmU9MH0sYXJlYUVuZDpmdW5jdGlvbigpe3RoaXMuX2xpbmU9TmFOfSxsaW5lU3RhcnQ6ZnVu
Y3Rpb24oKXt0aGlzLl94MD10aGlzLl94MT10aGlzLl95MD10aGlzLl95MT1OYU4sdGhpcy5fcG9p
bnQ9MH0sbGluZUVuZDpmdW5jdGlvbigpeyh0aGlzLl9saW5lfHwwIT09dGhpcy5fbGluZSYmMz09
PXRoaXMuX3BvaW50KSYmdGhpcy5fY29udGV4dC5jbG9zZVBhdGgoKSx0aGlzLl9saW5lPTEtdGhp
cy5fbGluZX0scG9pbnQ6ZnVuY3Rpb24odCxuKXtzd2l0Y2godD0rdCxuPStuLHRoaXMuX3BvaW50
KXtjYXNlIDA6dGhpcy5fcG9pbnQ9MTticmVhaztjYXNlIDE6dGhpcy5fcG9pbnQ9MjticmVhaztj
YXNlIDI6dGhpcy5fcG9pbnQ9Mzt2YXIgZT0odGhpcy5feDArNCp0aGlzLl94MSt0KS82LHI9KHRo
aXMuX3kwKzQqdGhpcy5feTErbikvNjt0aGlzLl9saW5lP3RoaXMuX2NvbnRleHQubGluZVRvKGUs
cik6dGhpcy5fY29udGV4dC5tb3ZlVG8oZSxyKTticmVhaztjYXNlIDM6dGhpcy5fcG9pbnQ9NDtk
ZWZhdWx0Ok5jKHRoaXMsdCxuKX10aGlzLl94MD10aGlzLl94MSx0aGlzLl94MT10LHRoaXMuX3kw
PXRoaXMuX3kxLHRoaXMuX3kxPW59fSxBYy5wcm90b3R5cGU9e2xpbmVTdGFydDpmdW5jdGlvbigp
e3RoaXMuX3g9W10sdGhpcy5feT1bXSx0aGlzLl9iYXNpcy5saW5lU3RhcnQoKX0sbGluZUVuZDpm
dW5jdGlvbigpe3ZhciB0PXRoaXMuX3gsbj10aGlzLl95LGU9dC5sZW5ndGgtMTtpZihlPjApZm9y
KHZhciByLGk9dFswXSxvPW5bMF0sdT10W2VdLWksYT1uW2VdLW8sYz0tMTsrK2M8PWU7KXI9Yy9l
LHRoaXMuX2Jhc2lzLnBvaW50KHRoaXMuX2JldGEqdFtjXSsoMS10aGlzLl9iZXRhKSooaStyKnUp
LHRoaXMuX2JldGEqbltjXSsoMS10aGlzLl9iZXRhKSoobytyKmEpKTt0aGlzLl94PXRoaXMuX3k9
bnVsbCx0aGlzLl9iYXNpcy5saW5lRW5kKCl9LHBvaW50OmZ1bmN0aW9uKHQsbil7dGhpcy5feC5w
dXNoKCt0KSx0aGlzLl95LnB1c2goK24pfX07dmFyIE5fPWZ1bmN0aW9uIHQobil7ZnVuY3Rpb24g
ZSh0KXtyZXR1cm4gMT09PW4/bmV3IGtjKHQpOm5ldyBBYyh0LG4pfXJldHVybiBlLmJldGE9ZnVu
Y3Rpb24obil7cmV0dXJuIHQoK24pfSxlfSguODUpO3pjLnByb3RvdHlwZT17YXJlYVN0YXJ0OmZ1
bmN0aW9uKCl7dGhpcy5fbGluZT0wfSxhcmVhRW5kOmZ1bmN0aW9uKCl7dGhpcy5fbGluZT1OYU59
LGxpbmVTdGFydDpmdW5jdGlvbigpe3RoaXMuX3gwPXRoaXMuX3gxPXRoaXMuX3gyPXRoaXMuX3kw
PXRoaXMuX3kxPXRoaXMuX3kyPU5hTix0aGlzLl9wb2ludD0wfSxsaW5lRW5kOmZ1bmN0aW9uKCl7
c3dpdGNoKHRoaXMuX3BvaW50KXtjYXNlIDI6dGhpcy5fY29udGV4dC5saW5lVG8odGhpcy5feDIs
dGhpcy5feTIpO2JyZWFrO2Nhc2UgMzpDYyh0aGlzLHRoaXMuX3gxLHRoaXMuX3kxKX0odGhpcy5f
bGluZXx8MCE9PXRoaXMuX2xpbmUmJjE9PT10aGlzLl9wb2ludCkmJnRoaXMuX2NvbnRleHQuY2xv
c2VQYXRoKCksdGhpcy5fbGluZT0xLXRoaXMuX2xpbmV9LHBvaW50OmZ1bmN0aW9uKHQsbil7c3dp
dGNoKHQ9K3Qsbj0rbix0aGlzLl9wb2ludCl7Y2FzZSAwOnRoaXMuX3BvaW50PTEsdGhpcy5fbGlu
ZT90aGlzLl9jb250ZXh0LmxpbmVUbyh0LG4pOnRoaXMuX2NvbnRleHQubW92ZVRvKHQsbik7YnJl
YWs7Y2FzZSAxOnRoaXMuX3BvaW50PTIsdGhpcy5feDE9dCx0aGlzLl95MT1uO2JyZWFrO2Nhc2Ug
Mjp0aGlzLl9wb2ludD0zO2RlZmF1bHQ6Q2ModGhpcyx0LG4pfXRoaXMuX3gwPXRoaXMuX3gxLHRo
aXMuX3gxPXRoaXMuX3gyLHRoaXMuX3gyPXQsdGhpcy5feTA9dGhpcy5feTEsdGhpcy5feTE9dGhp
cy5feTIsdGhpcy5feTI9bn19O3ZhciBrXz1mdW5jdGlvbiB0KG4pe2Z1bmN0aW9uIGUodCl7cmV0
dXJuIG5ldyB6Yyh0LG4pfXJldHVybiBlLnRlbnNpb249ZnVuY3Rpb24obil7cmV0dXJuIHQoK24p
fSxlfSgwKTtQYy5wcm90b3R5cGU9e2FyZWFTdGFydDpUYyxhcmVhRW5kOlRjLGxpbmVTdGFydDpm
dW5jdGlvbigpe3RoaXMuX3gwPXRoaXMuX3gxPXRoaXMuX3gyPXRoaXMuX3gzPXRoaXMuX3g0PXRo
aXMuX3g1PXRoaXMuX3kwPXRoaXMuX3kxPXRoaXMuX3kyPXRoaXMuX3kzPXRoaXMuX3k0PXRoaXMu
X3k1PU5hTix0aGlzLl9wb2ludD0wfSxsaW5lRW5kOmZ1bmN0aW9uKCl7c3dpdGNoKHRoaXMuX3Bv
aW50KXtjYXNlIDE6dGhpcy5fY29udGV4dC5tb3ZlVG8odGhpcy5feDMsdGhpcy5feTMpLHRoaXMu
X2NvbnRleHQuY2xvc2VQYXRoKCk7YnJlYWs7Y2FzZSAyOnRoaXMuX2NvbnRleHQubGluZVRvKHRo
aXMuX3gzLHRoaXMuX3kzKSx0aGlzLl9jb250ZXh0LmNsb3NlUGF0aCgpO2JyZWFrO2Nhc2UgMzp0
aGlzLnBvaW50KHRoaXMuX3gzLHRoaXMuX3kzKSx0aGlzLnBvaW50KHRoaXMuX3g0LHRoaXMuX3k0
KSx0aGlzLnBvaW50KHRoaXMuX3g1LHRoaXMuX3k1KX19LHBvaW50OmZ1bmN0aW9uKHQsbil7c3dp
dGNoKHQ9K3Qsbj0rbix0aGlzLl9wb2ludCl7Y2FzZSAwOnRoaXMuX3BvaW50PTEsdGhpcy5feDM9
dCx0aGlzLl95Mz1uO2JyZWFrO2Nhc2UgMTp0aGlzLl9wb2ludD0yLHRoaXMuX2NvbnRleHQubW92
ZVRvKHRoaXMuX3g0PXQsdGhpcy5feTQ9bik7YnJlYWs7Y2FzZSAyOnRoaXMuX3BvaW50PTMsdGhp
cy5feDU9dCx0aGlzLl95NT1uO2JyZWFrO2RlZmF1bHQ6Q2ModGhpcyx0LG4pfXRoaXMuX3gwPXRo
aXMuX3gxLHRoaXMuX3gxPXRoaXMuX3gyLHRoaXMuX3gyPXQsdGhpcy5feTA9dGhpcy5feTEsdGhp
cy5feTE9dGhpcy5feTIsdGhpcy5feTI9bn19O3ZhciBTXz1mdW5jdGlvbiB0KG4pe2Z1bmN0aW9u
IGUodCl7cmV0dXJuIG5ldyBQYyh0LG4pfXJldHVybiBlLnRlbnNpb249ZnVuY3Rpb24obil7cmV0
dXJuIHQoK24pfSxlfSgwKTtSYy5wcm90b3R5cGU9e2FyZWFTdGFydDpmdW5jdGlvbigpe3RoaXMu
X2xpbmU9MH0sYXJlYUVuZDpmdW5jdGlvbigpe3RoaXMuX2xpbmU9TmFOfSxsaW5lU3RhcnQ6ZnVu
Y3Rpb24oKXt0aGlzLl94MD10aGlzLl94MT10aGlzLl94Mj10aGlzLl95MD10aGlzLl95MT10aGlz
Ll95Mj1OYU4sdGhpcy5fcG9pbnQ9MH0sbGluZUVuZDpmdW5jdGlvbigpeyh0aGlzLl9saW5lfHww
IT09dGhpcy5fbGluZSYmMz09PXRoaXMuX3BvaW50KSYmdGhpcy5fY29udGV4dC5jbG9zZVBhdGgo
KSx0aGlzLl9saW5lPTEtdGhpcy5fbGluZX0scG9pbnQ6ZnVuY3Rpb24odCxuKXtzd2l0Y2godD0r
dCxuPStuLHRoaXMuX3BvaW50KXtjYXNlIDA6dGhpcy5fcG9pbnQ9MTticmVhaztjYXNlIDE6dGhp
cy5fcG9pbnQ9MjticmVhaztjYXNlIDI6dGhpcy5fcG9pbnQ9Myx0aGlzLl9saW5lP3RoaXMuX2Nv
bnRleHQubGluZVRvKHRoaXMuX3gyLHRoaXMuX3kyKTp0aGlzLl9jb250ZXh0Lm1vdmVUbyh0aGlz
Ll94Mix0aGlzLl95Mik7YnJlYWs7Y2FzZSAzOnRoaXMuX3BvaW50PTQ7ZGVmYXVsdDpDYyh0aGlz
LHQsbil9dGhpcy5feDA9dGhpcy5feDEsdGhpcy5feDE9dGhpcy5feDIsdGhpcy5feDI9dCx0aGlz
Ll95MD10aGlzLl95MSx0aGlzLl95MT10aGlzLl95Mix0aGlzLl95Mj1ufX07dmFyIEVfPWZ1bmN0
aW9uIHQobil7ZnVuY3Rpb24gZSh0KXtyZXR1cm4gbmV3IFJjKHQsbil9cmV0dXJuIGUudGVuc2lv
bj1mdW5jdGlvbihuKXtyZXR1cm4gdCgrbil9LGV9KDApO3FjLnByb3RvdHlwZT17YXJlYVN0YXJ0
OmZ1bmN0aW9uKCl7dGhpcy5fbGluZT0wfSxhcmVhRW5kOmZ1bmN0aW9uKCl7dGhpcy5fbGluZT1O
YU59LGxpbmVTdGFydDpmdW5jdGlvbigpe3RoaXMuX3gwPXRoaXMuX3gxPXRoaXMuX3gyPXRoaXMu
X3kwPXRoaXMuX3kxPXRoaXMuX3kyPU5hTix0aGlzLl9sMDFfYT10aGlzLl9sMTJfYT10aGlzLl9s
MjNfYT10aGlzLl9sMDFfMmE9dGhpcy5fbDEyXzJhPXRoaXMuX2wyM18yYT10aGlzLl9wb2ludD0w
fSxsaW5lRW5kOmZ1bmN0aW9uKCl7c3dpdGNoKHRoaXMuX3BvaW50KXtjYXNlIDI6dGhpcy5fY29u
dGV4dC5saW5lVG8odGhpcy5feDIsdGhpcy5feTIpO2JyZWFrO2Nhc2UgMzp0aGlzLnBvaW50KHRo
aXMuX3gyLHRoaXMuX3kyKX0odGhpcy5fbGluZXx8MCE9PXRoaXMuX2xpbmUmJjE9PT10aGlzLl9w
b2ludCkmJnRoaXMuX2NvbnRleHQuY2xvc2VQYXRoKCksdGhpcy5fbGluZT0xLXRoaXMuX2xpbmV9
LHBvaW50OmZ1bmN0aW9uKHQsbil7aWYodD0rdCxuPStuLHRoaXMuX3BvaW50KXt2YXIgZT10aGlz
Ll94Mi10LHI9dGhpcy5feTItbjt0aGlzLl9sMjNfYT1NYXRoLnNxcnQodGhpcy5fbDIzXzJhPU1h
dGgucG93KGUqZStyKnIsdGhpcy5fYWxwaGEpKX1zd2l0Y2godGhpcy5fcG9pbnQpe2Nhc2UgMDp0
aGlzLl9wb2ludD0xLHRoaXMuX2xpbmU/dGhpcy5fY29udGV4dC5saW5lVG8odCxuKTp0aGlzLl9j
b250ZXh0Lm1vdmVUbyh0LG4pO2JyZWFrO2Nhc2UgMTp0aGlzLl9wb2ludD0yO2JyZWFrO2Nhc2Ug
Mjp0aGlzLl9wb2ludD0zO2RlZmF1bHQ6TGModGhpcyx0LG4pfXRoaXMuX2wwMV9hPXRoaXMuX2wx
Ml9hLHRoaXMuX2wxMl9hPXRoaXMuX2wyM19hLHRoaXMuX2wwMV8yYT10aGlzLl9sMTJfMmEsdGhp
cy5fbDEyXzJhPXRoaXMuX2wyM18yYSx0aGlzLl94MD10aGlzLl94MSx0aGlzLl94MT10aGlzLl94
Mix0aGlzLl94Mj10LHRoaXMuX3kwPXRoaXMuX3kxLHRoaXMuX3kxPXRoaXMuX3kyLHRoaXMuX3ky
PW59fTt2YXIgQV89ZnVuY3Rpb24gdChuKXtmdW5jdGlvbiBlKHQpe3JldHVybiBuP25ldyBxYyh0
LG4pOm5ldyB6Yyh0LDApfXJldHVybiBlLmFscGhhPWZ1bmN0aW9uKG4pe3JldHVybiB0KCtuKX0s
ZX0oLjUpO0RjLnByb3RvdHlwZT17YXJlYVN0YXJ0OlRjLGFyZWFFbmQ6VGMsbGluZVN0YXJ0OmZ1
bmN0aW9uKCl7dGhpcy5feDA9dGhpcy5feDE9dGhpcy5feDI9dGhpcy5feDM9dGhpcy5feDQ9dGhp
cy5feDU9dGhpcy5feTA9dGhpcy5feTE9dGhpcy5feTI9dGhpcy5feTM9dGhpcy5feTQ9dGhpcy5f
eTU9TmFOLHRoaXMuX2wwMV9hPXRoaXMuX2wxMl9hPXRoaXMuX2wyM19hPXRoaXMuX2wwMV8yYT10
aGlzLl9sMTJfMmE9dGhpcy5fbDIzXzJhPXRoaXMuX3BvaW50PTB9LGxpbmVFbmQ6ZnVuY3Rpb24o
KXtzd2l0Y2godGhpcy5fcG9pbnQpe2Nhc2UgMTp0aGlzLl9jb250ZXh0Lm1vdmVUbyh0aGlzLl94
Myx0aGlzLl95MyksdGhpcy5fY29udGV4dC5jbG9zZVBhdGgoKTticmVhaztjYXNlIDI6dGhpcy5f
Y29udGV4dC5saW5lVG8odGhpcy5feDMsdGhpcy5feTMpLHRoaXMuX2NvbnRleHQuY2xvc2VQYXRo
KCk7YnJlYWs7Y2FzZSAzOnRoaXMucG9pbnQodGhpcy5feDMsdGhpcy5feTMpLHRoaXMucG9pbnQo
dGhpcy5feDQsdGhpcy5feTQpLHRoaXMucG9pbnQodGhpcy5feDUsdGhpcy5feTUpfX0scG9pbnQ6
ZnVuY3Rpb24odCxuKXtpZih0PSt0LG49K24sdGhpcy5fcG9pbnQpe3ZhciBlPXRoaXMuX3gyLXQs
cj10aGlzLl95Mi1uO3RoaXMuX2wyM19hPU1hdGguc3FydCh0aGlzLl9sMjNfMmE9TWF0aC5wb3co
ZSplK3Iqcix0aGlzLl9hbHBoYSkpfXN3aXRjaCh0aGlzLl9wb2ludCl7Y2FzZSAwOnRoaXMuX3Bv
aW50PTEsdGhpcy5feDM9dCx0aGlzLl95Mz1uO2JyZWFrO2Nhc2UgMTp0aGlzLl9wb2ludD0yLHRo
aXMuX2NvbnRleHQubW92ZVRvKHRoaXMuX3g0PXQsdGhpcy5feTQ9bik7YnJlYWs7Y2FzZSAyOnRo
aXMuX3BvaW50PTMsdGhpcy5feDU9dCx0aGlzLl95NT1uO2JyZWFrO2RlZmF1bHQ6TGModGhpcyx0
LG4pfXRoaXMuX2wwMV9hPXRoaXMuX2wxMl9hLHRoaXMuX2wxMl9hPXRoaXMuX2wyM19hLHRoaXMu
X2wwMV8yYT10aGlzLl9sMTJfMmEsdGhpcy5fbDEyXzJhPXRoaXMuX2wyM18yYSx0aGlzLl94MD10
aGlzLl94MSx0aGlzLl94MT10aGlzLl94Mix0aGlzLl94Mj10LHRoaXMuX3kwPXRoaXMuX3kxLHRo
aXMuX3kxPXRoaXMuX3kyLHRoaXMuX3kyPW59fTt2YXIgQ189ZnVuY3Rpb24gdChuKXtmdW5jdGlv
biBlKHQpe3JldHVybiBuP25ldyBEYyh0LG4pOm5ldyBQYyh0LDApfXJldHVybiBlLmFscGhhPWZ1
bmN0aW9uKG4pe3JldHVybiB0KCtuKX0sZX0oLjUpO1VjLnByb3RvdHlwZT17YXJlYVN0YXJ0OmZ1
bmN0aW9uKCl7dGhpcy5fbGluZT0wfSxhcmVhRW5kOmZ1bmN0aW9uKCl7dGhpcy5fbGluZT1OYU59
LGxpbmVTdGFydDpmdW5jdGlvbigpe3RoaXMuX3gwPXRoaXMuX3gxPXRoaXMuX3gyPXRoaXMuX3kw
PXRoaXMuX3kxPXRoaXMuX3kyPU5hTix0aGlzLl9sMDFfYT10aGlzLl9sMTJfYT10aGlzLl9sMjNf
YT10aGlzLl9sMDFfMmE9dGhpcy5fbDEyXzJhPXRoaXMuX2wyM18yYT10aGlzLl9wb2ludD0wfSxs
aW5lRW5kOmZ1bmN0aW9uKCl7KHRoaXMuX2xpbmV8fDAhPT10aGlzLl9saW5lJiYzPT09dGhpcy5f
cG9pbnQpJiZ0aGlzLl9jb250ZXh0LmNsb3NlUGF0aCgpLHRoaXMuX2xpbmU9MS10aGlzLl9saW5l
fSxwb2ludDpmdW5jdGlvbih0LG4pe2lmKHQ9K3Qsbj0rbix0aGlzLl9wb2ludCl7dmFyIGU9dGhp
cy5feDItdCxyPXRoaXMuX3kyLW47dGhpcy5fbDIzX2E9TWF0aC5zcXJ0KHRoaXMuX2wyM18yYT1N
YXRoLnBvdyhlKmUrcipyLHRoaXMuX2FscGhhKSl9c3dpdGNoKHRoaXMuX3BvaW50KXtjYXNlIDA6
dGhpcy5fcG9pbnQ9MTticmVhaztjYXNlIDE6dGhpcy5fcG9pbnQ9MjticmVhaztjYXNlIDI6dGhp
cy5fcG9pbnQ9Myx0aGlzLl9saW5lP3RoaXMuX2NvbnRleHQubGluZVRvKHRoaXMuX3gyLHRoaXMu
X3kyKTp0aGlzLl9jb250ZXh0Lm1vdmVUbyh0aGlzLl94Mix0aGlzLl95Mik7YnJlYWs7Y2FzZSAz
OnRoaXMuX3BvaW50PTQ7ZGVmYXVsdDpMYyh0aGlzLHQsbil9dGhpcy5fbDAxX2E9dGhpcy5fbDEy
X2EsdGhpcy5fbDEyX2E9dGhpcy5fbDIzX2EsdGhpcy5fbDAxXzJhPXRoaXMuX2wxMl8yYSx0aGlz
Ll9sMTJfMmE9dGhpcy5fbDIzXzJhLHRoaXMuX3gwPXRoaXMuX3gxLHRoaXMuX3gxPXRoaXMuX3gy
LHRoaXMuX3gyPXQsdGhpcy5feTA9dGhpcy5feTEsdGhpcy5feTE9dGhpcy5feTIsdGhpcy5feTI9
bn19O3ZhciB6Xz1mdW5jdGlvbiB0KG4pe2Z1bmN0aW9uIGUodCl7cmV0dXJuIG4/bmV3IFVjKHQs
bik6bmV3IFJjKHQsMCl9cmV0dXJuIGUuYWxwaGE9ZnVuY3Rpb24obil7cmV0dXJuIHQoK24pfSxl
fSguNSk7T2MucHJvdG90eXBlPXthcmVhU3RhcnQ6VGMsYXJlYUVuZDpUYyxsaW5lU3RhcnQ6ZnVu
Y3Rpb24oKXt0aGlzLl9wb2ludD0wfSxsaW5lRW5kOmZ1bmN0aW9uKCl7dGhpcy5fcG9pbnQmJnRo
aXMuX2NvbnRleHQuY2xvc2VQYXRoKCl9LHBvaW50OmZ1bmN0aW9uKHQsbil7dD0rdCxuPStuLHRo
aXMuX3BvaW50P3RoaXMuX2NvbnRleHQubGluZVRvKHQsbik6KHRoaXMuX3BvaW50PTEsdGhpcy5f
Y29udGV4dC5tb3ZlVG8odCxuKSl9fSxIYy5wcm90b3R5cGU9e2FyZWFTdGFydDpmdW5jdGlvbigp
e3RoaXMuX2xpbmU9MH0sYXJlYUVuZDpmdW5jdGlvbigpe3RoaXMuX2xpbmU9TmFOfSxsaW5lU3Rh
cnQ6ZnVuY3Rpb24oKXt0aGlzLl94MD10aGlzLl94MT10aGlzLl95MD10aGlzLl95MT10aGlzLl90
MD1OYU4sdGhpcy5fcG9pbnQ9MH0sbGluZUVuZDpmdW5jdGlvbigpe3N3aXRjaCh0aGlzLl9wb2lu
dCl7Y2FzZSAyOnRoaXMuX2NvbnRleHQubGluZVRvKHRoaXMuX3gxLHRoaXMuX3kxKTticmVhaztj
YXNlIDM6QmModGhpcyx0aGlzLl90MCxZYyh0aGlzLHRoaXMuX3QwKSl9KHRoaXMuX2xpbmV8fDAh
PT10aGlzLl9saW5lJiYxPT09dGhpcy5fcG9pbnQpJiZ0aGlzLl9jb250ZXh0LmNsb3NlUGF0aCgp
LHRoaXMuX2xpbmU9MS10aGlzLl9saW5lfSxwb2ludDpmdW5jdGlvbih0LG4pe3ZhciBlPU5hTjtp
Zih0PSt0LG49K24sdCE9PXRoaXMuX3gxfHxuIT09dGhpcy5feTEpe3N3aXRjaCh0aGlzLl9wb2lu
dCl7Y2FzZSAwOnRoaXMuX3BvaW50PTEsdGhpcy5fbGluZT90aGlzLl9jb250ZXh0LmxpbmVUbyh0
LG4pOnRoaXMuX2NvbnRleHQubW92ZVRvKHQsbik7YnJlYWs7Y2FzZSAxOnRoaXMuX3BvaW50PTI7
YnJlYWs7Y2FzZSAyOnRoaXMuX3BvaW50PTMsQmModGhpcyxZYyh0aGlzLGU9SWModGhpcyx0LG4p
KSxlKTticmVhaztkZWZhdWx0OkJjKHRoaXMsdGhpcy5fdDAsZT1JYyh0aGlzLHQsbikpfXRoaXMu
X3gwPXRoaXMuX3gxLHRoaXMuX3gxPXQsdGhpcy5feTA9dGhpcy5feTEsdGhpcy5feTE9bix0aGlz
Ll90MD1lfX19LChqYy5wcm90b3R5cGU9T2JqZWN0LmNyZWF0ZShIYy5wcm90b3R5cGUpKS5wb2lu
dD1mdW5jdGlvbih0LG4pe0hjLnByb3RvdHlwZS5wb2ludC5jYWxsKHRoaXMsbix0KX0sWGMucHJv
dG90eXBlPXttb3ZlVG86ZnVuY3Rpb24odCxuKXt0aGlzLl9jb250ZXh0Lm1vdmVUbyhuLHQpfSxj
bG9zZVBhdGg6ZnVuY3Rpb24oKXt0aGlzLl9jb250ZXh0LmNsb3NlUGF0aCgpfSxsaW5lVG86ZnVu
Y3Rpb24odCxuKXt0aGlzLl9jb250ZXh0LmxpbmVUbyhuLHQpfSxiZXppZXJDdXJ2ZVRvOmZ1bmN0
aW9uKHQsbixlLHIsaSxvKXt0aGlzLl9jb250ZXh0LmJlemllckN1cnZlVG8obix0LHIsZSxvLGkp
fX0sVmMucHJvdG90eXBlPXthcmVhU3RhcnQ6ZnVuY3Rpb24oKXt0aGlzLl9saW5lPTB9LGFyZWFF
bmQ6ZnVuY3Rpb24oKXt0aGlzLl9saW5lPU5hTn0sbGluZVN0YXJ0OmZ1bmN0aW9uKCl7dGhpcy5f
eD1bXSx0aGlzLl95PVtdfSxsaW5lRW5kOmZ1bmN0aW9uKCl7dmFyIHQ9dGhpcy5feCxuPXRoaXMu
X3ksZT10Lmxlbmd0aDtpZihlKWlmKHRoaXMuX2xpbmU/dGhpcy5fY29udGV4dC5saW5lVG8odFsw
XSxuWzBdKTp0aGlzLl9jb250ZXh0Lm1vdmVUbyh0WzBdLG5bMF0pLDI9PT1lKXRoaXMuX2NvbnRl
eHQubGluZVRvKHRbMV0sblsxXSk7ZWxzZSBmb3IodmFyIHI9JGModCksaT0kYyhuKSxvPTAsdT0x
O3U8ZTsrK28sKyt1KXRoaXMuX2NvbnRleHQuYmV6aWVyQ3VydmVUbyhyWzBdW29dLGlbMF1bb10s
clsxXVtvXSxpWzFdW29dLHRbdV0sblt1XSk7KHRoaXMuX2xpbmV8fDAhPT10aGlzLl9saW5lJiYx
PT09ZSkmJnRoaXMuX2NvbnRleHQuY2xvc2VQYXRoKCksdGhpcy5fbGluZT0xLXRoaXMuX2xpbmUs
dGhpcy5feD10aGlzLl95PW51bGx9LHBvaW50OmZ1bmN0aW9uKHQsbil7dGhpcy5feC5wdXNoKCt0
KSx0aGlzLl95LnB1c2goK24pfX0sV2MucHJvdG90eXBlPXthcmVhU3RhcnQ6ZnVuY3Rpb24oKXt0
aGlzLl9saW5lPTB9LGFyZWFFbmQ6ZnVuY3Rpb24oKXt0aGlzLl9saW5lPU5hTn0sbGluZVN0YXJ0
OmZ1bmN0aW9uKCl7dGhpcy5feD10aGlzLl95PU5hTix0aGlzLl9wb2ludD0wfSxsaW5lRW5kOmZ1
bmN0aW9uKCl7MDx0aGlzLl90JiZ0aGlzLl90PDEmJjI9PT10aGlzLl9wb2ludCYmdGhpcy5fY29u
dGV4dC5saW5lVG8odGhpcy5feCx0aGlzLl95KSwodGhpcy5fbGluZXx8MCE9PXRoaXMuX2xpbmUm
JjE9PT10aGlzLl9wb2ludCkmJnRoaXMuX2NvbnRleHQuY2xvc2VQYXRoKCksdGhpcy5fbGluZT49
MCYmKHRoaXMuX3Q9MS10aGlzLl90LHRoaXMuX2xpbmU9MS10aGlzLl9saW5lKX0scG9pbnQ6ZnVu
Y3Rpb24odCxuKXtzd2l0Y2godD0rdCxuPStuLHRoaXMuX3BvaW50KXtjYXNlIDA6dGhpcy5fcG9p
bnQ9MSx0aGlzLl9saW5lP3RoaXMuX2NvbnRleHQubGluZVRvKHQsbik6dGhpcy5fY29udGV4dC5t
b3ZlVG8odCxuKTticmVhaztjYXNlIDE6dGhpcy5fcG9pbnQ9MjtkZWZhdWx0OmlmKHRoaXMuX3Q8
PTApdGhpcy5fY29udGV4dC5saW5lVG8odGhpcy5feCxuKSx0aGlzLl9jb250ZXh0LmxpbmVUbyh0
LG4pO2Vsc2V7dmFyIGU9dGhpcy5feCooMS10aGlzLl90KSt0KnRoaXMuX3Q7dGhpcy5fY29udGV4
dC5saW5lVG8oZSx0aGlzLl95KSx0aGlzLl9jb250ZXh0LmxpbmVUbyhlLG4pfX10aGlzLl94PXQs
dGhpcy5feT1ufX0scnMucHJvdG90eXBlPXtjb25zdHJ1Y3RvcjpycyxpbnNlcnQ6ZnVuY3Rpb24o
dCxuKXt2YXIgZSxyLGk7aWYodCl7aWYobi5QPXQsbi5OPXQuTix0Lk4mJih0Lk4uUD1uKSx0Lk49
bix0LlIpe2Zvcih0PXQuUjt0Lkw7KXQ9dC5MO3QuTD1ufWVsc2UgdC5SPW47ZT10fWVsc2UgdGhp
cy5fPyh0PWFzKHRoaXMuXyksbi5QPW51bGwsbi5OPXQsdC5QPXQuTD1uLGU9dCk6KG4uUD1uLk49
bnVsbCx0aGlzLl89bixlPW51bGwpO2ZvcihuLkw9bi5SPW51bGwsbi5VPWUsbi5DPSEwLHQ9bjtl
JiZlLkM7KWU9PT0ocj1lLlUpLkw/KGk9ci5SKSYmaS5DPyhlLkM9aS5DPSExLHIuQz0hMCx0PXIp
Oih0PT09ZS5SJiYob3ModGhpcyxlKSxlPSh0PWUpLlUpLGUuQz0hMSxyLkM9ITAsdXModGhpcyxy
KSk6KGk9ci5MKSYmaS5DPyhlLkM9aS5DPSExLHIuQz0hMCx0PXIpOih0PT09ZS5MJiYodXModGhp
cyxlKSxlPSh0PWUpLlUpLGUuQz0hMSxyLkM9ITAsb3ModGhpcyxyKSksZT10LlU7dGhpcy5fLkM9
ITF9LHJlbW92ZTpmdW5jdGlvbih0KXt0Lk4mJih0Lk4uUD10LlApLHQuUCYmKHQuUC5OPXQuTiks
dC5OPXQuUD1udWxsO3ZhciBuLGUscixpPXQuVSxvPXQuTCx1PXQuUjtpZihlPW8/dT9hcyh1KTpv
OnUsaT9pLkw9PT10P2kuTD1lOmkuUj1lOnRoaXMuXz1lLG8mJnU/KHI9ZS5DLGUuQz10LkMsZS5M
PW8sby5VPWUsZSE9PXU/KGk9ZS5VLGUuVT10LlUsdD1lLlIsaS5MPXQsZS5SPXUsdS5VPWUpOihl
LlU9aSxpPWUsdD1lLlIpKToocj10LkMsdD1lKSx0JiYodC5VPWkpLCFyKWlmKHQmJnQuQyl0LkM9
ITE7ZWxzZXtkb3tpZih0PT09dGhpcy5fKWJyZWFrO2lmKHQ9PT1pLkwpe2lmKChuPWkuUikuQyYm
KG4uQz0hMSxpLkM9ITAsb3ModGhpcyxpKSxuPWkuUiksbi5MJiZuLkwuQ3x8bi5SJiZuLlIuQyl7
bi5SJiZuLlIuQ3x8KG4uTC5DPSExLG4uQz0hMCx1cyh0aGlzLG4pLG49aS5SKSxuLkM9aS5DLGku
Qz1uLlIuQz0hMSxvcyh0aGlzLGkpLHQ9dGhpcy5fO2JyZWFrfX1lbHNlIGlmKChuPWkuTCkuQyYm
KG4uQz0hMSxpLkM9ITAsdXModGhpcyxpKSxuPWkuTCksbi5MJiZuLkwuQ3x8bi5SJiZuLlIuQyl7
bi5MJiZuLkwuQ3x8KG4uUi5DPSExLG4uQz0hMCxvcyh0aGlzLG4pLG49aS5MKSxuLkM9aS5DLGku
Qz1uLkwuQz0hMSx1cyh0aGlzLGkpLHQ9dGhpcy5fO2JyZWFrfW4uQz0hMCx0PWksaT1pLlV9d2hp
bGUoIXQuQyk7dCYmKHQuQz0hMSl9fX07dmFyIFBfLFJfLExfLHFfLERfLFVfPVtdLE9fPVtdLEZf
PTFlLTYsSV89MWUtMTI7TnMucHJvdG90eXBlPXtjb25zdHJ1Y3RvcjpOcyxwb2x5Z29uczpmdW5j
dGlvbigpe3ZhciB0PXRoaXMuZWRnZXM7cmV0dXJuIHRoaXMuY2VsbHMubWFwKGZ1bmN0aW9uKG4p
e3ZhciBlPW4uaGFsZmVkZ2VzLm1hcChmdW5jdGlvbihlKXtyZXR1cm4gZHMobix0W2VdKX0pO3Jl
dHVybiBlLmRhdGE9bi5zaXRlLmRhdGEsZX0pfSx0cmlhbmdsZXM6ZnVuY3Rpb24oKXt2YXIgdD1b
XSxuPXRoaXMuZWRnZXM7cmV0dXJuIHRoaXMuY2VsbHMuZm9yRWFjaChmdW5jdGlvbihlLHIpe2lm
KG89KGk9ZS5oYWxmZWRnZXMpLmxlbmd0aClmb3IodmFyIGksbyx1LGE9ZS5zaXRlLGM9LTEscz1u
W2lbby0xXV0sZj1zLmxlZnQ9PT1hP3MucmlnaHQ6cy5sZWZ0OysrYzxvOyl1PWYsZj0ocz1uW2lb
Y11dKS5sZWZ0PT09YT9zLnJpZ2h0OnMubGVmdCx1JiZmJiZyPHUuaW5kZXgmJnI8Zi5pbmRleCYm
TXMoYSx1LGYpPDAmJnQucHVzaChbYS5kYXRhLHUuZGF0YSxmLmRhdGFdKX0pLHR9LGxpbmtzOmZ1
bmN0aW9uKCl7cmV0dXJuIHRoaXMuZWRnZXMuZmlsdGVyKGZ1bmN0aW9uKHQpe3JldHVybiB0LnJp
Z2h0fSkubWFwKGZ1bmN0aW9uKHQpe3JldHVybntzb3VyY2U6dC5sZWZ0LmRhdGEsdGFyZ2V0OnQu
cmlnaHQuZGF0YX19KX0sZmluZDpmdW5jdGlvbih0LG4sZSl7Zm9yKHZhciByLGksbz10aGlzLHU9
by5fZm91bmR8fDAsYT1vLmNlbGxzLmxlbmd0aDshKGk9by5jZWxsc1t1XSk7KWlmKCsrdT49YSly
ZXR1cm4gbnVsbDt2YXIgYz10LWkuc2l0ZVswXSxzPW4taS5zaXRlWzFdLGY9YypjK3Mqcztkb3tp
PW8uY2VsbHNbcj11XSx1PW51bGwsaS5oYWxmZWRnZXMuZm9yRWFjaChmdW5jdGlvbihlKXt2YXIg
cj1vLmVkZ2VzW2VdLGE9ci5sZWZ0O2lmKGEhPT1pLnNpdGUmJmF8fChhPXIucmlnaHQpKXt2YXIg
Yz10LWFbMF0scz1uLWFbMV0sbD1jKmMrcypzO2w8ZiYmKGY9bCx1PWEuaW5kZXgpfX0pfXdoaWxl
KG51bGwhPT11KTtyZXR1cm4gby5fZm91bmQ9cixudWxsPT1lfHxmPD1lKmU/aS5zaXRlOm51bGx9
fSxTcy5wcm90b3R5cGU9e2NvbnN0cnVjdG9yOlNzLHNjYWxlOmZ1bmN0aW9uKHQpe3JldHVybiAx
PT09dD90aGlzOm5ldyBTcyh0aGlzLmsqdCx0aGlzLngsdGhpcy55KX0sdHJhbnNsYXRlOmZ1bmN0
aW9uKHQsbil7cmV0dXJuIDA9PT10JjA9PT1uP3RoaXM6bmV3IFNzKHRoaXMuayx0aGlzLngrdGhp
cy5rKnQsdGhpcy55K3RoaXMuaypuKX0sYXBwbHk6ZnVuY3Rpb24odCl7cmV0dXJuW3RbMF0qdGhp
cy5rK3RoaXMueCx0WzFdKnRoaXMuayt0aGlzLnldfSxhcHBseVg6ZnVuY3Rpb24odCl7cmV0dXJu
IHQqdGhpcy5rK3RoaXMueH0sYXBwbHlZOmZ1bmN0aW9uKHQpe3JldHVybiB0KnRoaXMuayt0aGlz
Lnl9LGludmVydDpmdW5jdGlvbih0KXtyZXR1cm5bKHRbMF0tdGhpcy54KS90aGlzLmssKHRbMV0t
dGhpcy55KS90aGlzLmtdfSxpbnZlcnRYOmZ1bmN0aW9uKHQpe3JldHVybih0LXRoaXMueCkvdGhp
cy5rfSxpbnZlcnRZOmZ1bmN0aW9uKHQpe3JldHVybih0LXRoaXMueSkvdGhpcy5rfSxyZXNjYWxl
WDpmdW5jdGlvbih0KXtyZXR1cm4gdC5jb3B5KCkuZG9tYWluKHQucmFuZ2UoKS5tYXAodGhpcy5p
bnZlcnRYLHRoaXMpLm1hcCh0LmludmVydCx0KSl9LHJlc2NhbGVZOmZ1bmN0aW9uKHQpe3JldHVy
biB0LmNvcHkoKS5kb21haW4odC5yYW5nZSgpLm1hcCh0aGlzLmludmVydFksdGhpcykubWFwKHQu
aW52ZXJ0LHQpKX0sdG9TdHJpbmc6ZnVuY3Rpb24oKXtyZXR1cm4idHJhbnNsYXRlKCIrdGhpcy54
KyIsIit0aGlzLnkrIikgc2NhbGUoIit0aGlzLmsrIikifX07dmFyIFlfPW5ldyBTcygxLDAsMCk7
RXMucHJvdG90eXBlPVNzLnByb3RvdHlwZSx0LnZlcnNpb249IjQuMTMuMCIsdC5iaXNlY3Q9T3Ms
dC5iaXNlY3RSaWdodD1Pcyx0LmJpc2VjdExlZnQ9RnMsdC5hc2NlbmRpbmc9bix0LmJpc2VjdG9y
PWUsdC5jcm9zcz1mdW5jdGlvbih0LG4sZSl7dmFyIGksbyx1LGEsYz10Lmxlbmd0aCxzPW4ubGVu
Z3RoLGY9bmV3IEFycmF5KGMqcyk7Zm9yKG51bGw9PWUmJihlPXIpLGk9dT0wO2k8YzsrK2kpZm9y
KGE9dFtpXSxvPTA7bzxzOysrbywrK3UpZlt1XT1lKGEsbltvXSk7cmV0dXJuIGZ9LHQuZGVzY2Vu
ZGluZz1mdW5jdGlvbih0LG4pe3JldHVybiBuPHQ/LTE6bj50PzE6bj49dD8wOk5hTn0sdC5kZXZp
YXRpb249dSx0LmV4dGVudD1hLHQuaGlzdG9ncmFtPWZ1bmN0aW9uKCl7ZnVuY3Rpb24gdCh0KXt2
YXIgaSxvLHU9dC5sZW5ndGgsYT1uZXcgQXJyYXkodSk7Zm9yKGk9MDtpPHU7KytpKWFbaV09bih0
W2ldLGksdCk7dmFyIGM9ZShhKSxzPWNbMF0sbD1jWzFdLGg9cihhLHMsbCk7QXJyYXkuaXNBcnJh
eShoKXx8KGg9cChzLGwsaCksaD1mKE1hdGguY2VpbChzL2gpKmgsTWF0aC5mbG9vcihsL2gpKmgs
aCkpO2Zvcih2YXIgZD1oLmxlbmd0aDtoWzBdPD1zOyloLnNoaWZ0KCksLS1kO2Zvcig7aFtkLTFd
Pmw7KWgucG9wKCksLS1kO3ZhciB2LGc9bmV3IEFycmF5KGQrMSk7Zm9yKGk9MDtpPD1kOysraSko
dj1nW2ldPVtdKS54MD1pPjA/aFtpLTFdOnMsdi54MT1pPGQ/aFtpXTpsO2ZvcihpPTA7aTx1Oysr
aSlzPD0obz1hW2ldKSYmbzw9bCYmZ1tPcyhoLG8sMCxkKV0ucHVzaCh0W2ldKTtyZXR1cm4gZ312
YXIgbj1zLGU9YSxyPWQ7cmV0dXJuIHQudmFsdWU9ZnVuY3Rpb24oZSl7cmV0dXJuIGFyZ3VtZW50
cy5sZW5ndGg/KG49ImZ1bmN0aW9uIj09dHlwZW9mIGU/ZTpjKGUpLHQpOm59LHQuZG9tYWluPWZ1
bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhlPSJmdW5jdGlvbiI9PXR5cGVvZiBu
P246YyhbblswXSxuWzFdXSksdCk6ZX0sdC50aHJlc2hvbGRzPWZ1bmN0aW9uKG4pe3JldHVybiBh
cmd1bWVudHMubGVuZ3RoPyhyPSJmdW5jdGlvbiI9PXR5cGVvZiBuP246QXJyYXkuaXNBcnJheShu
KT9jKFlzLmNhbGwobikpOmMobiksdCk6cn0sdH0sdC50aHJlc2hvbGRGcmVlZG1hbkRpYWNvbmlz
PWZ1bmN0aW9uKHQsZSxyKXtyZXR1cm4gdD1Ccy5jYWxsKHQsaSkuc29ydChuKSxNYXRoLmNlaWwo
KHItZSkvKDIqKHYodCwuNzUpLXYodCwuMjUpKSpNYXRoLnBvdyh0Lmxlbmd0aCwtMS8zKSkpfSx0
LnRocmVzaG9sZFNjb3R0PWZ1bmN0aW9uKHQsbixlKXtyZXR1cm4gTWF0aC5jZWlsKChlLW4pLygz
LjUqdSh0KSpNYXRoLnBvdyh0Lmxlbmd0aCwtMS8zKSkpfSx0LnRocmVzaG9sZFN0dXJnZXM9ZCx0
Lm1heD1mdW5jdGlvbih0LG4pe3ZhciBlLHIsaT10Lmxlbmd0aCxvPS0xO2lmKG51bGw9PW4pe2Zv
cig7KytvPGk7KWlmKG51bGwhPShlPXRbb10pJiZlPj1lKWZvcihyPWU7KytvPGk7KW51bGwhPShl
PXRbb10pJiZlPnImJihyPWUpfWVsc2UgZm9yKDsrK288aTspaWYobnVsbCE9KGU9bih0W29dLG8s
dCkpJiZlPj1lKWZvcihyPWU7KytvPGk7KW51bGwhPShlPW4odFtvXSxvLHQpKSYmZT5yJiYocj1l
KTtyZXR1cm4gcn0sdC5tZWFuPWZ1bmN0aW9uKHQsbil7dmFyIGUscj10Lmxlbmd0aCxvPXIsdT0t
MSxhPTA7aWYobnVsbD09bilmb3IoOysrdTxyOylpc05hTihlPWkodFt1XSkpPy0tbzphKz1lO2Vs
c2UgZm9yKDsrK3U8cjspaXNOYU4oZT1pKG4odFt1XSx1LHQpKSk/LS1vOmErPWU7aWYobylyZXR1
cm4gYS9vfSx0Lm1lZGlhbj1mdW5jdGlvbih0LGUpe3ZhciByLG89dC5sZW5ndGgsdT0tMSxhPVtd
O2lmKG51bGw9PWUpZm9yKDsrK3U8bzspaXNOYU4ocj1pKHRbdV0pKXx8YS5wdXNoKHIpO2Vsc2Ug
Zm9yKDsrK3U8bzspaXNOYU4ocj1pKGUodFt1XSx1LHQpKSl8fGEucHVzaChyKTtyZXR1cm4gdihh
LnNvcnQobiksLjUpfSx0Lm1lcmdlPWcsdC5taW49Xyx0LnBhaXJzPWZ1bmN0aW9uKHQsbil7bnVs
bD09biYmKG49cik7Zm9yKHZhciBlPTAsaT10Lmxlbmd0aC0xLG89dFswXSx1PW5ldyBBcnJheShp
PDA/MDppKTtlPGk7KXVbZV09bihvLG89dFsrK2VdKTtyZXR1cm4gdX0sdC5wZXJtdXRlPWZ1bmN0
aW9uKHQsbil7Zm9yKHZhciBlPW4ubGVuZ3RoLHI9bmV3IEFycmF5KGUpO2UtLTspcltlXT10W25b
ZV1dO3JldHVybiByfSx0LnF1YW50aWxlPXYsdC5yYW5nZT1mLHQuc2Nhbj1mdW5jdGlvbih0LGUp
e2lmKHI9dC5sZW5ndGgpe3ZhciByLGksbz0wLHU9MCxhPXRbdV07Zm9yKG51bGw9PWUmJihlPW4p
OysrbzxyOykoZShpPXRbb10sYSk8MHx8MCE9PWUoYSxhKSkmJihhPWksdT1vKTtyZXR1cm4gMD09
PWUoYSxhKT91OnZvaWQgMH19LHQuc2h1ZmZsZT1mdW5jdGlvbih0LG4sZSl7Zm9yKHZhciByLGks
bz0obnVsbD09ZT90Lmxlbmd0aDplKS0obj1udWxsPT1uPzA6K24pO287KWk9TWF0aC5yYW5kb20o
KSpvLS18MCxyPXRbbytuXSx0W28rbl09dFtpK25dLHRbaStuXT1yO3JldHVybiB0fSx0LnN1bT1m
dW5jdGlvbih0LG4pe3ZhciBlLHI9dC5sZW5ndGgsaT0tMSxvPTA7aWYobnVsbD09bilmb3IoOysr
aTxyOykoZT0rdFtpXSkmJihvKz1lKTtlbHNlIGZvcig7KytpPHI7KShlPStuKHRbaV0saSx0KSkm
JihvKz1lKTtyZXR1cm4gb30sdC50aWNrcz1sLHQudGlja0luY3JlbWVudD1oLHQudGlja1N0ZXA9
cCx0LnRyYW5zcG9zZT15LHQudmFyaWFuY2U9byx0LnppcD1mdW5jdGlvbigpe3JldHVybiB5KGFy
Z3VtZW50cyl9LHQuYXhpc1RvcD1mdW5jdGlvbih0KXtyZXR1cm4gVCgkcyx0KX0sdC5heGlzUmln
aHQ9ZnVuY3Rpb24odCl7cmV0dXJuIFQoV3MsdCl9LHQuYXhpc0JvdHRvbT1mdW5jdGlvbih0KXty
ZXR1cm4gVChacyx0KX0sdC5heGlzTGVmdD1mdW5jdGlvbih0KXtyZXR1cm4gVChHcyx0KX0sdC5i
cnVzaD1mdW5jdGlvbigpe3JldHVybiBLbihvaCl9LHQuYnJ1c2hYPWZ1bmN0aW9uKCl7cmV0dXJu
IEtuKHJoKX0sdC5icnVzaFk9ZnVuY3Rpb24oKXtyZXR1cm4gS24oaWgpfSx0LmJydXNoU2VsZWN0
aW9uPWZ1bmN0aW9uKHQpe3ZhciBuPXQuX19icnVzaDtyZXR1cm4gbj9uLmRpbS5vdXRwdXQobi5z
ZWxlY3Rpb24pOm51bGx9LHQuY2hvcmQ9ZnVuY3Rpb24oKXtmdW5jdGlvbiB0KHQpe3ZhciBvLHUs
YSxjLHMsbCxoPXQubGVuZ3RoLHA9W10sZD1mKGgpLHY9W10sZz1bXSxfPWcuZ3JvdXBzPW5ldyBB
cnJheShoKSx5PW5ldyBBcnJheShoKmgpO2ZvcihvPTAscz0tMTsrK3M8aDspe2Zvcih1PTAsbD0t
MTsrK2w8aDspdSs9dFtzXVtsXTtwLnB1c2godSksdi5wdXNoKGYoaCkpLG8rPXV9Zm9yKGUmJmQu
c29ydChmdW5jdGlvbih0LG4pe3JldHVybiBlKHBbdF0scFtuXSl9KSxyJiZ2LmZvckVhY2goZnVu
Y3Rpb24obixlKXtuLnNvcnQoZnVuY3Rpb24obixpKXtyZXR1cm4gcih0W2VdW25dLHRbZV1baV0p
fSl9KSxjPShvPWdoKDAsdmgtbipoKS9vKT9uOnZoL2gsdT0wLHM9LTE7KytzPGg7KXtmb3IoYT11
LGw9LTE7KytsPGg7KXt2YXIgbT1kW3NdLHg9dlttXVtsXSxiPXRbbV1beF0sdz11LE09dSs9Yipv
O3lbeCpoK21dPXtpbmRleDptLHN1YmluZGV4Ongsc3RhcnRBbmdsZTp3LGVuZEFuZ2xlOk0sdmFs
dWU6Yn19X1ttXT17aW5kZXg6bSxzdGFydEFuZ2xlOmEsZW5kQW5nbGU6dSx2YWx1ZTpwW21dfSx1
Kz1jfWZvcihzPS0xOysrczxoOylmb3IobD1zLTE7KytsPGg7KXt2YXIgVD15W2wqaCtzXSxOPXlb
cypoK2xdOyhULnZhbHVlfHxOLnZhbHVlKSYmZy5wdXNoKFQudmFsdWU8Ti52YWx1ZT97c291cmNl
Ok4sdGFyZ2V0OlR9Ontzb3VyY2U6VCx0YXJnZXQ6Tn0pfXJldHVybiBpP2cuc29ydChpKTpnfXZh
ciBuPTAsZT1udWxsLHI9bnVsbCxpPW51bGw7cmV0dXJuIHQucGFkQW5nbGU9ZnVuY3Rpb24oZSl7
cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KG49Z2goMCxlKSx0KTpufSx0LnNvcnRHcm91cHM9ZnVu
Y3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KGU9bix0KTplfSx0LnNvcnRTdWJncm91
cHM9ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KHI9bix0KTpyfSx0LnNvcnRD
aG9yZHM9ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KG51bGw9PW4/aT1udWxs
OihpPWZ1bmN0aW9uKHQpe3JldHVybiBmdW5jdGlvbihuLGUpe3JldHVybiB0KG4uc291cmNlLnZh
bHVlK24udGFyZ2V0LnZhbHVlLGUuc291cmNlLnZhbHVlK2UudGFyZ2V0LnZhbHVlKX19KG4pKS5f
PW4sdCk6aSYmaS5ffSx0fSx0LnJpYmJvbj1mdW5jdGlvbigpe2Z1bmN0aW9uIHQoKXt2YXIgdCxh
PV9oLmNhbGwoYXJndW1lbnRzKSxjPW4uYXBwbHkodGhpcyxhKSxzPWUuYXBwbHkodGhpcyxhKSxm
PStyLmFwcGx5KHRoaXMsKGFbMF09YyxhKSksbD1pLmFwcGx5KHRoaXMsYSktZGgsaD1vLmFwcGx5
KHRoaXMsYSktZGgscD1mKmxoKGwpLGQ9ZipoaChsKSx2PStyLmFwcGx5KHRoaXMsKGFbMF09cyxh
KSksZz1pLmFwcGx5KHRoaXMsYSktZGgsXz1vLmFwcGx5KHRoaXMsYSktZGg7aWYodXx8KHU9dD1l
ZSgpKSx1Lm1vdmVUbyhwLGQpLHUuYXJjKDAsMCxmLGwsaCksbD09PWcmJmg9PT1ffHwodS5xdWFk
cmF0aWNDdXJ2ZVRvKDAsMCx2KmxoKGcpLHYqaGgoZykpLHUuYXJjKDAsMCx2LGcsXykpLHUucXVh
ZHJhdGljQ3VydmVUbygwLDAscCxkKSx1LmNsb3NlUGF0aCgpLHQpcmV0dXJuIHU9bnVsbCx0KyIi
fHxudWxsfXZhciBuPXJlLGU9aWUscj1vZSxpPXVlLG89YWUsdT1udWxsO3JldHVybiB0LnJhZGl1
cz1mdW5jdGlvbihuKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8ocj0iZnVuY3Rpb24iPT10eXBl
b2Ygbj9uOnRlKCtuKSx0KTpyfSx0LnN0YXJ0QW5nbGU9ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3Vt
ZW50cy5sZW5ndGg/KGk9ImZ1bmN0aW9uIj09dHlwZW9mIG4/bjp0ZSgrbiksdCk6aX0sdC5lbmRB
bmdsZT1mdW5jdGlvbihuKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8obz0iZnVuY3Rpb24iPT10
eXBlb2Ygbj9uOnRlKCtuKSx0KTpvfSx0LnNvdXJjZT1mdW5jdGlvbihlKXtyZXR1cm4gYXJndW1l
bnRzLmxlbmd0aD8obj1lLHQpOm59LHQudGFyZ2V0PWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVu
dHMubGVuZ3RoPyhlPW4sdCk6ZX0sdC5jb250ZXh0PWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVu
dHMubGVuZ3RoPyh1PW51bGw9PW4/bnVsbDpuLHQpOnV9LHR9LHQubmVzdD1mdW5jdGlvbigpe2Z1
bmN0aW9uIHQobixpLHUsYSl7aWYoaT49by5sZW5ndGgpcmV0dXJuIG51bGwhPWUmJm4uc29ydChl
KSxudWxsIT1yP3Iobik6bjtmb3IodmFyIGMscyxmLGw9LTEsaD1uLmxlbmd0aCxwPW9baSsrXSxk
PXNlKCksdj11KCk7KytsPGg7KShmPWQuZ2V0KGM9cChzPW5bbF0pKyIiKSk/Zi5wdXNoKHMpOmQu
c2V0KGMsW3NdKTtyZXR1cm4gZC5lYWNoKGZ1bmN0aW9uKG4sZSl7YSh2LGUsdChuLGksdSxhKSl9
KSx2fWZ1bmN0aW9uIG4odCxlKXtpZigrK2U+by5sZW5ndGgpcmV0dXJuIHQ7dmFyIGksYT11W2Ut
MV07cmV0dXJuIG51bGwhPXImJmU+PW8ubGVuZ3RoP2k9dC5lbnRyaWVzKCk6KGk9W10sdC5lYWNo
KGZ1bmN0aW9uKHQscil7aS5wdXNoKHtrZXk6cix2YWx1ZXM6bih0LGUpfSl9KSksbnVsbCE9YT9p
LnNvcnQoZnVuY3Rpb24odCxuKXtyZXR1cm4gYSh0LmtleSxuLmtleSl9KTppfXZhciBlLHIsaSxv
PVtdLHU9W107cmV0dXJuIGk9e29iamVjdDpmdW5jdGlvbihuKXtyZXR1cm4gdChuLDAsZmUsbGUp
fSxtYXA6ZnVuY3Rpb24obil7cmV0dXJuIHQobiwwLGhlLHBlKX0sZW50cmllczpmdW5jdGlvbihl
KXtyZXR1cm4gbih0KGUsMCxoZSxwZSksMCl9LGtleTpmdW5jdGlvbih0KXtyZXR1cm4gby5wdXNo
KHQpLGl9LHNvcnRLZXlzOmZ1bmN0aW9uKHQpe3JldHVybiB1W28ubGVuZ3RoLTFdPXQsaX0sc29y
dFZhbHVlczpmdW5jdGlvbih0KXtyZXR1cm4gZT10LGl9LHJvbGx1cDpmdW5jdGlvbih0KXtyZXR1
cm4gcj10LGl9fX0sdC5zZXQ9dmUsdC5tYXA9c2UsdC5rZXlzPWZ1bmN0aW9uKHQpe3ZhciBuPVtd
O2Zvcih2YXIgZSBpbiB0KW4ucHVzaChlKTtyZXR1cm4gbn0sdC52YWx1ZXM9ZnVuY3Rpb24odCl7
dmFyIG49W107Zm9yKHZhciBlIGluIHQpbi5wdXNoKHRbZV0pO3JldHVybiBufSx0LmVudHJpZXM9
ZnVuY3Rpb24odCl7dmFyIG49W107Zm9yKHZhciBlIGluIHQpbi5wdXNoKHtrZXk6ZSx2YWx1ZTp0
W2VdfSk7cmV0dXJuIG59LHQuY29sb3I9RXQsdC5yZ2I9UHQsdC5oc2w9cXQsdC5sYWI9RnQsdC5o
Y2w9WHQsdC5jdWJlaGVsaXg9JHQsdC5kaXNwYXRjaD1OLHQuZHJhZz1mdW5jdGlvbigpe2Z1bmN0
aW9uIG4odCl7dC5vbigibW91c2Vkb3duLmRyYWciLGUpLmZpbHRlcihnKS5vbigidG91Y2hzdGFy
dC5kcmFnIixvKS5vbigidG91Y2htb3ZlLmRyYWciLHUpLm9uKCJ0b3VjaGVuZC5kcmFnIHRvdWNo
Y2FuY2VsLmRyYWciLGEpLnN0eWxlKCJ0b3VjaC1hY3Rpb24iLCJub25lIikuc3R5bGUoIi13ZWJr
aXQtdGFwLWhpZ2hsaWdodC1jb2xvciIsInJnYmEoMCwwLDAsMCkiKX1mdW5jdGlvbiBlKCl7aWYo
IWgmJnAuYXBwbHkodGhpcyxhcmd1bWVudHMpKXt2YXIgbj1jKCJtb3VzZSIsZC5hcHBseSh0aGlz
LGFyZ3VtZW50cykscHQsdGhpcyxhcmd1bWVudHMpO24mJihjdCh0LmV2ZW50LnZpZXcpLm9uKCJt
b3VzZW1vdmUuZHJhZyIsciwhMCkub24oIm1vdXNldXAuZHJhZyIsaSwhMCksX3QodC5ldmVudC52
aWV3KSx2dCgpLGw9ITEscz10LmV2ZW50LmNsaWVudFgsZj10LmV2ZW50LmNsaWVudFksbigic3Rh
cnQiKSl9fWZ1bmN0aW9uIHIoKXtpZihndCgpLCFsKXt2YXIgbj10LmV2ZW50LmNsaWVudFgtcyxl
PXQuZXZlbnQuY2xpZW50WS1mO2w9bipuK2UqZT54fV8ubW91c2UoImRyYWciKX1mdW5jdGlvbiBp
KCl7Y3QodC5ldmVudC52aWV3KS5vbigibW91c2Vtb3ZlLmRyYWcgbW91c2V1cC5kcmFnIixudWxs
KSx5dCh0LmV2ZW50LnZpZXcsbCksZ3QoKSxfLm1vdXNlKCJlbmQiKX1mdW5jdGlvbiBvKCl7aWYo
cC5hcHBseSh0aGlzLGFyZ3VtZW50cykpe3ZhciBuLGUscj10LmV2ZW50LmNoYW5nZWRUb3VjaGVz
LGk9ZC5hcHBseSh0aGlzLGFyZ3VtZW50cyksbz1yLmxlbmd0aDtmb3Iobj0wO248bzsrK24pKGU9
YyhyW25dLmlkZW50aWZpZXIsaSxkdCx0aGlzLGFyZ3VtZW50cykpJiYodnQoKSxlKCJzdGFydCIp
KX19ZnVuY3Rpb24gdSgpe3ZhciBuLGUscj10LmV2ZW50LmNoYW5nZWRUb3VjaGVzLGk9ci5sZW5n
dGg7Zm9yKG49MDtuPGk7KytuKShlPV9bcltuXS5pZGVudGlmaWVyXSkmJihndCgpLGUoImRyYWci
KSl9ZnVuY3Rpb24gYSgpe3ZhciBuLGUscj10LmV2ZW50LmNoYW5nZWRUb3VjaGVzLGk9ci5sZW5n
dGg7Zm9yKGgmJmNsZWFyVGltZW91dChoKSxoPXNldFRpbWVvdXQoZnVuY3Rpb24oKXtoPW51bGx9
LDUwMCksbj0wO248aTsrK24pKGU9X1tyW25dLmlkZW50aWZpZXJdKSYmKHZ0KCksZSgiZW5kIikp
fWZ1bmN0aW9uIGMoZSxyLGksbyx1KXt2YXIgYSxjLHMsZj1pKHIsZSksbD15LmNvcHkoKTtpZihp
dChuZXcgeHQobiwiYmVmb3Jlc3RhcnQiLGEsZSxtLGZbMF0sZlsxXSwwLDAsbCksZnVuY3Rpb24o
KXtyZXR1cm4gbnVsbCE9KHQuZXZlbnQuc3ViamVjdD1hPXYuYXBwbHkobyx1KSkmJihjPWEueC1m
WzBdfHwwLHM9YS55LWZbMV18fDAsITApfSkpcmV0dXJuIGZ1bmN0aW9uIHQoaCl7dmFyIHAsZD1m
O3N3aXRjaChoKXtjYXNlInN0YXJ0IjpfW2VdPXQscD1tKys7YnJlYWs7Y2FzZSJlbmQiOmRlbGV0
ZSBfW2VdLC0tbTtjYXNlImRyYWciOmY9aShyLGUpLHA9bX1pdChuZXcgeHQobixoLGEsZSxwLGZb
MF0rYyxmWzFdK3MsZlswXS1kWzBdLGZbMV0tZFsxXSxsKSxsLmFwcGx5LGwsW2gsbyx1XSl9fXZh
ciBzLGYsbCxoLHA9YnQsZD13dCx2PU10LGc9VHQsXz17fSx5PU4oInN0YXJ0IiwiZHJhZyIsImVu
ZCIpLG09MCx4PTA7cmV0dXJuIG4uZmlsdGVyPWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMu
bGVuZ3RoPyhwPSJmdW5jdGlvbiI9PXR5cGVvZiB0P3Q6bXQoISF0KSxuKTpwfSxuLmNvbnRhaW5l
cj1mdW5jdGlvbih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oZD0iZnVuY3Rpb24iPT10eXBl
b2YgdD90Om10KHQpLG4pOmR9LG4uc3ViamVjdD1mdW5jdGlvbih0KXtyZXR1cm4gYXJndW1lbnRz
Lmxlbmd0aD8odj0iZnVuY3Rpb24iPT10eXBlb2YgdD90Om10KHQpLG4pOnZ9LG4udG91Y2hhYmxl
PWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhnPSJmdW5jdGlvbiI9PXR5cGVv
ZiB0P3Q6bXQoISF0KSxuKTpnfSxuLm9uPWZ1bmN0aW9uKCl7dmFyIHQ9eS5vbi5hcHBseSh5LGFy
Z3VtZW50cyk7cmV0dXJuIHQ9PT15P246dH0sbi5jbGlja0Rpc3RhbmNlPWZ1bmN0aW9uKHQpe3Jl
dHVybiBhcmd1bWVudHMubGVuZ3RoPyh4PSh0PSt0KSp0LG4pOk1hdGguc3FydCh4KX0sbn0sdC5k
cmFnRGlzYWJsZT1fdCx0LmRyYWdFbmFibGU9eXQsdC5kc3ZGb3JtYXQ9X2UsdC5jc3ZQYXJzZT1F
aCx0LmNzdlBhcnNlUm93cz1BaCx0LmNzdkZvcm1hdD1DaCx0LmNzdkZvcm1hdFJvd3M9emgsdC50
c3ZQYXJzZT1SaCx0LnRzdlBhcnNlUm93cz1MaCx0LnRzdkZvcm1hdD1xaCx0LnRzdkZvcm1hdFJv
d3M9RGgsdC5lYXNlTGluZWFyPWZ1bmN0aW9uKHQpe3JldHVybit0fSx0LmVhc2VRdWFkPU9uLHQu
ZWFzZVF1YWRJbj1mdW5jdGlvbih0KXtyZXR1cm4gdCp0fSx0LmVhc2VRdWFkT3V0PWZ1bmN0aW9u
KHQpe3JldHVybiB0KigyLXQpfSx0LmVhc2VRdWFkSW5PdXQ9T24sdC5lYXNlQ3ViaWM9Rm4sdC5l
YXNlQ3ViaWNJbj1mdW5jdGlvbih0KXtyZXR1cm4gdCp0KnR9LHQuZWFzZUN1YmljT3V0PWZ1bmN0
aW9uKHQpe3JldHVybi0tdCp0KnQrMX0sdC5lYXNlQ3ViaWNJbk91dD1Gbix0LmVhc2VQb2x5PXps
LHQuZWFzZVBvbHlJbj1BbCx0LmVhc2VQb2x5T3V0PUNsLHQuZWFzZVBvbHlJbk91dD16bCx0LmVh
c2VTaW49SW4sdC5lYXNlU2luSW49ZnVuY3Rpb24odCl7cmV0dXJuIDEtTWF0aC5jb3ModCpSbCl9
LHQuZWFzZVNpbk91dD1mdW5jdGlvbih0KXtyZXR1cm4gTWF0aC5zaW4odCpSbCl9LHQuZWFzZVNp
bkluT3V0PUluLHQuZWFzZUV4cD1Zbix0LmVhc2VFeHBJbj1mdW5jdGlvbih0KXtyZXR1cm4gTWF0
aC5wb3coMiwxMCp0LTEwKX0sdC5lYXNlRXhwT3V0PWZ1bmN0aW9uKHQpe3JldHVybiAxLU1hdGgu
cG93KDIsLTEwKnQpfSx0LmVhc2VFeHBJbk91dD1Zbix0LmVhc2VDaXJjbGU9Qm4sdC5lYXNlQ2ly
Y2xlSW49ZnVuY3Rpb24odCl7cmV0dXJuIDEtTWF0aC5zcXJ0KDEtdCp0KX0sdC5lYXNlQ2lyY2xl
T3V0PWZ1bmN0aW9uKHQpe3JldHVybiBNYXRoLnNxcnQoMS0gLS10KnQpfSx0LmVhc2VDaXJjbGVJ
bk91dD1Cbix0LmVhc2VCb3VuY2U9SG4sdC5lYXNlQm91bmNlSW49ZnVuY3Rpb24odCl7cmV0dXJu
IDEtSG4oMS10KX0sdC5lYXNlQm91bmNlT3V0PUhuLHQuZWFzZUJvdW5jZUluT3V0PWZ1bmN0aW9u
KHQpe3JldHVybigodCo9Mik8PTE/MS1IbigxLXQpOkhuKHQtMSkrMSkvMn0sdC5lYXNlQmFjaz1W
bCx0LmVhc2VCYWNrSW49amwsdC5lYXNlQmFja091dD1YbCx0LmVhc2VCYWNrSW5PdXQ9VmwsdC5l
YXNlRWxhc3RpYz1abCx0LmVhc2VFbGFzdGljSW49V2wsdC5lYXNlRWxhc3RpY091dD1abCx0LmVh
c2VFbGFzdGljSW5PdXQ9R2wsdC5mb3JjZUNlbnRlcj1mdW5jdGlvbih0LG4pe2Z1bmN0aW9uIGUo
KXt2YXIgZSxpLG89ci5sZW5ndGgsdT0wLGE9MDtmb3IoZT0wO2U8bzsrK2UpdSs9KGk9cltlXSku
eCxhKz1pLnk7Zm9yKHU9dS9vLXQsYT1hL28tbixlPTA7ZTxvOysrZSkoaT1yW2VdKS54LT11LGku
eS09YX12YXIgcjtyZXR1cm4gbnVsbD09dCYmKHQ9MCksbnVsbD09biYmKG49MCksZS5pbml0aWFs
aXplPWZ1bmN0aW9uKHQpe3I9dH0sZS54PWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVu
Z3RoPyh0PStuLGUpOnR9LGUueT1mdW5jdGlvbih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8o
bj0rdCxlKTpufSxlfSx0LmZvcmNlQ29sbGlkZT1mdW5jdGlvbih0KXtmdW5jdGlvbiBuKCl7Zm9y
KHZhciB0LG4scixjLHMsZixsLGg9aS5sZW5ndGgscD0wO3A8YTsrK3ApZm9yKG49VGUoaSxTZSxF
ZSkudmlzaXRBZnRlcihlKSx0PTA7dDxoOysrdClyPWlbdF0sZj1vW3IuaW5kZXhdLGw9ZipmLGM9
ci54K3Iudngscz1yLnkrci52eSxuLnZpc2l0KGZ1bmN0aW9uKHQsbixlLGksbyl7dmFyIGE9dC5k
YXRhLGg9dC5yLHA9ZitoO2lmKCFhKXJldHVybiBuPmMrcHx8aTxjLXB8fGU+cytwfHxvPHMtcDtp
ZihhLmluZGV4PnIuaW5kZXgpe3ZhciBkPWMtYS54LWEudngsdj1zLWEueS1hLnZ5LGc9ZCpkK3Yq
djtnPHAqcCYmKDA9PT1kJiYoZD1tZSgpLGcrPWQqZCksMD09PXYmJih2PW1lKCksZys9dip2KSxn
PShwLShnPU1hdGguc3FydChnKSkpL2cqdSxyLnZ4Kz0oZCo9ZykqKHA9KGgqPWgpLyhsK2gpKSxy
LnZ5Kz0odio9ZykqcCxhLnZ4LT1kKihwPTEtcCksYS52eS09dipwKX19KX1mdW5jdGlvbiBlKHQp
e2lmKHQuZGF0YSlyZXR1cm4gdC5yPW9bdC5kYXRhLmluZGV4XTtmb3IodmFyIG49dC5yPTA7bjw0
Oysrbil0W25dJiZ0W25dLnI+dC5yJiYodC5yPXRbbl0ucil9ZnVuY3Rpb24gcigpe2lmKGkpe3Zh
ciBuLGUscj1pLmxlbmd0aDtmb3Iobz1uZXcgQXJyYXkociksbj0wO248cjsrK24pZT1pW25dLG9b
ZS5pbmRleF09K3QoZSxuLGkpfX12YXIgaSxvLHU9MSxhPTE7cmV0dXJuImZ1bmN0aW9uIiE9dHlw
ZW9mIHQmJih0PXllKG51bGw9PXQ/MTordCkpLG4uaW5pdGlhbGl6ZT1mdW5jdGlvbih0KXtpPXQs
cigpfSxuLml0ZXJhdGlvbnM9ZnVuY3Rpb24odCl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KGE9
K3Qsbik6YX0sbi5zdHJlbmd0aD1mdW5jdGlvbih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8o
dT0rdCxuKTp1fSxuLnJhZGl1cz1mdW5jdGlvbihlKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8o
dD0iZnVuY3Rpb24iPT10eXBlb2YgZT9lOnllKCtlKSxyKCksbik6dH0sbn0sdC5mb3JjZUxpbms9
ZnVuY3Rpb24odCl7ZnVuY3Rpb24gbihuKXtmb3IodmFyIGU9MCxyPXQubGVuZ3RoO2U8cDsrK2Up
Zm9yKHZhciBpLGEsYyxmLGwsaCxkLHY9MDt2PHI7Kyt2KWE9KGk9dFt2XSkuc291cmNlLGY9KGM9
aS50YXJnZXQpLngrYy52eC1hLngtYS52eHx8bWUoKSxsPWMueStjLnZ5LWEueS1hLnZ5fHxtZSgp
LGYqPWg9KChoPU1hdGguc3FydChmKmYrbCpsKSktdVt2XSkvaCpuKm9bdl0sbCo9aCxjLnZ4LT1m
KihkPXNbdl0pLGMudnktPWwqZCxhLnZ4Kz1mKihkPTEtZCksYS52eSs9bCpkfWZ1bmN0aW9uIGUo
KXtpZihhKXt2YXIgbixlLGw9YS5sZW5ndGgsaD10Lmxlbmd0aCxwPXNlKGEsZik7Zm9yKG49MCxj
PW5ldyBBcnJheShsKTtuPGg7KytuKShlPXRbbl0pLmluZGV4PW4sIm9iamVjdCIhPXR5cGVvZiBl
LnNvdXJjZSYmKGUuc291cmNlPUNlKHAsZS5zb3VyY2UpKSwib2JqZWN0IiE9dHlwZW9mIGUudGFy
Z2V0JiYoZS50YXJnZXQ9Q2UocCxlLnRhcmdldCkpLGNbZS5zb3VyY2UuaW5kZXhdPShjW2Uuc291
cmNlLmluZGV4XXx8MCkrMSxjW2UudGFyZ2V0LmluZGV4XT0oY1tlLnRhcmdldC5pbmRleF18fDAp
KzE7Zm9yKG49MCxzPW5ldyBBcnJheShoKTtuPGg7KytuKWU9dFtuXSxzW25dPWNbZS5zb3VyY2Uu
aW5kZXhdLyhjW2Uuc291cmNlLmluZGV4XStjW2UudGFyZ2V0LmluZGV4XSk7bz1uZXcgQXJyYXko
aCkscigpLHU9bmV3IEFycmF5KGgpLGkoKX19ZnVuY3Rpb24gcigpe2lmKGEpZm9yKHZhciBuPTAs
ZT10Lmxlbmd0aDtuPGU7KytuKW9bbl09K2wodFtuXSxuLHQpfWZ1bmN0aW9uIGkoKXtpZihhKWZv
cih2YXIgbj0wLGU9dC5sZW5ndGg7bjxlOysrbil1W25dPStoKHRbbl0sbix0KX12YXIgbyx1LGEs
YyxzLGY9QWUsbD1mdW5jdGlvbih0KXtyZXR1cm4gMS9NYXRoLm1pbihjW3Quc291cmNlLmluZGV4
XSxjW3QudGFyZ2V0LmluZGV4XSl9LGg9eWUoMzApLHA9MTtyZXR1cm4gbnVsbD09dCYmKHQ9W10p
LG4uaW5pdGlhbGl6ZT1mdW5jdGlvbih0KXthPXQsZSgpfSxuLmxpbmtzPWZ1bmN0aW9uKHIpe3Jl
dHVybiBhcmd1bWVudHMubGVuZ3RoPyh0PXIsZSgpLG4pOnR9LG4uaWQ9ZnVuY3Rpb24odCl7cmV0
dXJuIGFyZ3VtZW50cy5sZW5ndGg/KGY9dCxuKTpmfSxuLml0ZXJhdGlvbnM9ZnVuY3Rpb24odCl7
cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KHA9K3Qsbik6cH0sbi5zdHJlbmd0aD1mdW5jdGlvbih0
KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8obD0iZnVuY3Rpb24iPT10eXBlb2YgdD90OnllKCt0
KSxyKCksbik6bH0sbi5kaXN0YW5jZT1mdW5jdGlvbih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0
aD8oaD0iZnVuY3Rpb24iPT10eXBlb2YgdD90OnllKCt0KSxpKCksbik6aH0sbn0sdC5mb3JjZU1h
bnlCb2R5PWZ1bmN0aW9uKCl7ZnVuY3Rpb24gdCh0KXt2YXIgbixhPWkubGVuZ3RoLGM9VGUoaSx6
ZSxQZSkudmlzaXRBZnRlcihlKTtmb3IodT10LG49MDtuPGE7KytuKW89aVtuXSxjLnZpc2l0KHIp
fWZ1bmN0aW9uIG4oKXtpZihpKXt2YXIgdCxuLGU9aS5sZW5ndGg7Zm9yKGE9bmV3IEFycmF5KGUp
LHQ9MDt0PGU7Kyt0KW49aVt0XSxhW24uaW5kZXhdPStjKG4sdCxpKX19ZnVuY3Rpb24gZSh0KXt2
YXIgbixlLHIsaSxvLHU9MCxjPTA7aWYodC5sZW5ndGgpe2ZvcihyPWk9bz0wO288NDsrK28pKG49
dFtvXSkmJihlPU1hdGguYWJzKG4udmFsdWUpKSYmKHUrPW4udmFsdWUsYys9ZSxyKz1lKm4ueCxp
Kz1lKm4ueSk7dC54PXIvYyx0Lnk9aS9jfWVsc2V7KG49dCkueD1uLmRhdGEueCxuLnk9bi5kYXRh
Lnk7ZG97dSs9YVtuLmRhdGEuaW5kZXhdfXdoaWxlKG49bi5uZXh0KX10LnZhbHVlPXV9ZnVuY3Rp
b24gcih0LG4sZSxyKXtpZighdC52YWx1ZSlyZXR1cm4hMDt2YXIgaT10Lngtby54LGM9dC55LW8u
eSxoPXItbixwPWkqaStjKmM7aWYoaCpoL2w8cClyZXR1cm4gcDxmJiYoMD09PWkmJihpPW1lKCks
cCs9aSppKSwwPT09YyYmKGM9bWUoKSxwKz1jKmMpLHA8cyYmKHA9TWF0aC5zcXJ0KHMqcCkpLG8u
dngrPWkqdC52YWx1ZSp1L3Asby52eSs9Yyp0LnZhbHVlKnUvcCksITA7aWYoISh0Lmxlbmd0aHx8
cD49Zikpeyh0LmRhdGEhPT1vfHx0Lm5leHQpJiYoMD09PWkmJihpPW1lKCkscCs9aSppKSwwPT09
YyYmKGM9bWUoKSxwKz1jKmMpLHA8cyYmKHA9TWF0aC5zcXJ0KHMqcCkpKTtkb3t0LmRhdGEhPT1v
JiYoaD1hW3QuZGF0YS5pbmRleF0qdS9wLG8udngrPWkqaCxvLnZ5Kz1jKmgpfXdoaWxlKHQ9dC5u
ZXh0KX19dmFyIGksbyx1LGEsYz15ZSgtMzApLHM9MSxmPTEvMCxsPS44MTtyZXR1cm4gdC5pbml0
aWFsaXplPWZ1bmN0aW9uKHQpe2k9dCxuKCl9LHQuc3RyZW5ndGg9ZnVuY3Rpb24oZSl7cmV0dXJu
IGFyZ3VtZW50cy5sZW5ndGg/KGM9ImZ1bmN0aW9uIj09dHlwZW9mIGU/ZTp5ZSgrZSksbigpLHQp
OmN9LHQuZGlzdGFuY2VNaW49ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KHM9
bipuLHQpOk1hdGguc3FydChzKX0sdC5kaXN0YW5jZU1heD1mdW5jdGlvbihuKXtyZXR1cm4gYXJn
dW1lbnRzLmxlbmd0aD8oZj1uKm4sdCk6TWF0aC5zcXJ0KGYpfSx0LnRoZXRhPWZ1bmN0aW9uKG4p
e3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhsPW4qbix0KTpNYXRoLnNxcnQobCl9LHR9LHQuZm9y
Y2VSYWRpYWw9ZnVuY3Rpb24odCxuLGUpe2Z1bmN0aW9uIHIodCl7Zm9yKHZhciByPTAsaT1vLmxl
bmd0aDtyPGk7KytyKXt2YXIgYz1vW3JdLHM9Yy54LW58fDFlLTYsZj1jLnktZXx8MWUtNixsPU1h
dGguc3FydChzKnMrZipmKSxoPShhW3JdLWwpKnVbcl0qdC9sO2MudngrPXMqaCxjLnZ5Kz1mKmh9
fWZ1bmN0aW9uIGkoKXtpZihvKXt2YXIgbixlPW8ubGVuZ3RoO2Zvcih1PW5ldyBBcnJheShlKSxh
PW5ldyBBcnJheShlKSxuPTA7bjxlOysrbilhW25dPSt0KG9bbl0sbixvKSx1W25dPWlzTmFOKGFb
bl0pPzA6K2Mob1tuXSxuLG8pfX12YXIgbyx1LGEsYz15ZSguMSk7cmV0dXJuImZ1bmN0aW9uIiE9
dHlwZW9mIHQmJih0PXllKCt0KSksbnVsbD09biYmKG49MCksbnVsbD09ZSYmKGU9MCksci5pbml0
aWFsaXplPWZ1bmN0aW9uKHQpe289dCxpKCl9LHIuc3RyZW5ndGg9ZnVuY3Rpb24odCl7cmV0dXJu
IGFyZ3VtZW50cy5sZW5ndGg/KGM9ImZ1bmN0aW9uIj09dHlwZW9mIHQ/dDp5ZSgrdCksaSgpLHIp
OmN9LHIucmFkaXVzPWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyh0PSJmdW5j
dGlvbiI9PXR5cGVvZiBuP246eWUoK24pLGkoKSxyKTp0fSxyLng9ZnVuY3Rpb24odCl7cmV0dXJu
IGFyZ3VtZW50cy5sZW5ndGg/KG49K3Qscik6bn0sci55PWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1
bWVudHMubGVuZ3RoPyhlPSt0LHIpOmV9LHJ9LHQuZm9yY2VTaW11bGF0aW9uPWZ1bmN0aW9uKHQp
e2Z1bmN0aW9uIG4oKXtlKCkscC5jYWxsKCJ0aWNrIixvKSx1PGEmJihoLnN0b3AoKSxwLmNhbGwo
ImVuZCIsbykpfWZ1bmN0aW9uIGUoKXt2YXIgbixlLHI9dC5sZW5ndGg7Zm9yKHUrPShzLXUpKmMs
bC5lYWNoKGZ1bmN0aW9uKHQpe3QodSl9KSxuPTA7bjxyOysrbiludWxsPT0oZT10W25dKS5meD9l
LngrPWUudngqPWY6KGUueD1lLmZ4LGUudng9MCksbnVsbD09ZS5meT9lLnkrPWUudnkqPWY6KGUu
eT1lLmZ5LGUudnk9MCl9ZnVuY3Rpb24gcigpe2Zvcih2YXIgbixlPTAscj10Lmxlbmd0aDtlPHI7
KytlKXtpZihuPXRbZV0sbi5pbmRleD1lLGlzTmFOKG4ueCl8fGlzTmFOKG4ueSkpe3ZhciBpPUZo
Kk1hdGguc3FydChlKSxvPWUqSWg7bi54PWkqTWF0aC5jb3Mobyksbi55PWkqTWF0aC5zaW4obyl9
KGlzTmFOKG4udngpfHxpc05hTihuLnZ5KSkmJihuLnZ4PW4udnk9MCl9fWZ1bmN0aW9uIGkobil7
cmV0dXJuIG4uaW5pdGlhbGl6ZSYmbi5pbml0aWFsaXplKHQpLG59dmFyIG8sdT0xLGE9LjAwMSxj
PTEtTWF0aC5wb3coYSwxLzMwMCkscz0wLGY9LjYsbD1zZSgpLGg9d24obikscD1OKCJ0aWNrIiwi
ZW5kIik7cmV0dXJuIG51bGw9PXQmJih0PVtdKSxyKCksbz17dGljazplLHJlc3RhcnQ6ZnVuY3Rp
b24oKXtyZXR1cm4gaC5yZXN0YXJ0KG4pLG99LHN0b3A6ZnVuY3Rpb24oKXtyZXR1cm4gaC5zdG9w
KCksb30sbm9kZXM6ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KHQ9bixyKCks
bC5lYWNoKGkpLG8pOnR9LGFscGhhOmZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3Ro
Pyh1PSt0LG8pOnV9LGFscGhhTWluOmZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3Ro
PyhhPSt0LG8pOmF9LGFscGhhRGVjYXk6ZnVuY3Rpb24odCl7cmV0dXJuIGFyZ3VtZW50cy5sZW5n
dGg/KGM9K3Qsbyk6K2N9LGFscGhhVGFyZ2V0OmZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMu
bGVuZ3RoPyhzPSt0LG8pOnN9LHZlbG9jaXR5RGVjYXk6ZnVuY3Rpb24odCl7cmV0dXJuIGFyZ3Vt
ZW50cy5sZW5ndGg/KGY9MS10LG8pOjEtZn0sZm9yY2U6ZnVuY3Rpb24odCxuKXtyZXR1cm4gYXJn
dW1lbnRzLmxlbmd0aD4xPyhudWxsPT1uP2wucmVtb3ZlKHQpOmwuc2V0KHQsaShuKSksbyk6bC5n
ZXQodCl9LGZpbmQ6ZnVuY3Rpb24obixlLHIpe3ZhciBpLG8sdSxhLGMscz0wLGY9dC5sZW5ndGg7
Zm9yKG51bGw9PXI/cj0xLzA6cio9cixzPTA7czxmOysrcykodT0oaT1uLShhPXRbc10pLngpKmkr
KG89ZS1hLnkpKm8pPHImJihjPWEscj11KTtyZXR1cm4gY30sb246ZnVuY3Rpb24odCxuKXtyZXR1
cm4gYXJndW1lbnRzLmxlbmd0aD4xPyhwLm9uKHQsbiksbyk6cC5vbih0KX19fSx0LmZvcmNlWD1m
dW5jdGlvbih0KXtmdW5jdGlvbiBuKHQpe2Zvcih2YXIgbixlPTAsdT1yLmxlbmd0aDtlPHU7Kytl
KShuPXJbZV0pLnZ4Kz0ob1tlXS1uLngpKmlbZV0qdH1mdW5jdGlvbiBlKCl7aWYocil7dmFyIG4s
ZT1yLmxlbmd0aDtmb3IoaT1uZXcgQXJyYXkoZSksbz1uZXcgQXJyYXkoZSksbj0wO248ZTsrK24p
aVtuXT1pc05hTihvW25dPSt0KHJbbl0sbixyKSk/MDordShyW25dLG4scil9fXZhciByLGksbyx1
PXllKC4xKTtyZXR1cm4iZnVuY3Rpb24iIT10eXBlb2YgdCYmKHQ9eWUobnVsbD09dD8wOit0KSks
bi5pbml0aWFsaXplPWZ1bmN0aW9uKHQpe3I9dCxlKCl9LG4uc3RyZW5ndGg9ZnVuY3Rpb24odCl7
cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KHU9ImZ1bmN0aW9uIj09dHlwZW9mIHQ/dDp5ZSgrdCks
ZSgpLG4pOnV9LG4ueD1mdW5jdGlvbihyKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8odD0iZnVu
Y3Rpb24iPT10eXBlb2Ygcj9yOnllKCtyKSxlKCksbik6dH0sbn0sdC5mb3JjZVk9ZnVuY3Rpb24o
dCl7ZnVuY3Rpb24gbih0KXtmb3IodmFyIG4sZT0wLHU9ci5sZW5ndGg7ZTx1OysrZSkobj1yW2Vd
KS52eSs9KG9bZV0tbi55KSppW2VdKnR9ZnVuY3Rpb24gZSgpe2lmKHIpe3ZhciBuLGU9ci5sZW5n
dGg7Zm9yKGk9bmV3IEFycmF5KGUpLG89bmV3IEFycmF5KGUpLG49MDtuPGU7KytuKWlbbl09aXNO
YU4ob1tuXT0rdChyW25dLG4scikpPzA6K3UocltuXSxuLHIpfX12YXIgcixpLG8sdT15ZSguMSk7
cmV0dXJuImZ1bmN0aW9uIiE9dHlwZW9mIHQmJih0PXllKG51bGw9PXQ/MDordCkpLG4uaW5pdGlh
bGl6ZT1mdW5jdGlvbih0KXtyPXQsZSgpfSxuLnN0cmVuZ3RoPWZ1bmN0aW9uKHQpe3JldHVybiBh
cmd1bWVudHMubGVuZ3RoPyh1PSJmdW5jdGlvbiI9PXR5cGVvZiB0P3Q6eWUoK3QpLGUoKSxuKTp1
fSxuLnk9ZnVuY3Rpb24ocil7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KHQ9ImZ1bmN0aW9uIj09
dHlwZW9mIHI/cjp5ZSgrciksZSgpLG4pOnR9LG59LHQuZm9ybWF0RGVmYXVsdExvY2FsZT1JZSx0
LmZvcm1hdExvY2FsZT1GZSx0LmZvcm1hdFNwZWNpZmllcj1EZSx0LnByZWNpc2lvbkZpeGVkPVll
LHQucHJlY2lzaW9uUHJlZml4PUJlLHQucHJlY2lzaW9uUm91bmQ9SGUsdC5nZW9BcmVhPWZ1bmN0
aW9uKHQpe3JldHVybiBWcC5yZXNldCgpLHRyKHQsJHApLDIqVnB9LHQuZ2VvQm91bmRzPWZ1bmN0
aW9uKHQpe3ZhciBuLGUscixpLG8sdSxhO2lmKEtoPUpoPS0oR2g9UWg9MS8wKSxpcD1bXSx0cih0
LFpwKSxlPWlwLmxlbmd0aCl7Zm9yKGlwLnNvcnQoeHIpLG49MSxvPVtyPWlwWzBdXTtuPGU7Kytu
KWJyKHIsKGk9aXBbbl0pWzBdKXx8YnIocixpWzFdKT8obXIoclswXSxpWzFdKT5tcihyWzBdLHJb
MV0pJiYoclsxXT1pWzFdKSxtcihpWzBdLHJbMV0pPm1yKHJbMF0sclsxXSkmJihyWzBdPWlbMF0p
KTpvLnB1c2gocj1pKTtmb3IodT0tMS8wLG49MCxyPW9bZT1vLmxlbmd0aC0xXTtuPD1lO3I9aSwr
K24paT1vW25dLChhPW1yKHJbMV0saVswXSkpPnUmJih1PWEsR2g9aVswXSxKaD1yWzFdKX1yZXR1
cm4gaXA9b3A9bnVsbCxHaD09PTEvMHx8UWg9PT0xLzA/W1tOYU4sTmFOXSxbTmFOLE5hTl1dOltb
R2gsUWhdLFtKaCxLaF1dfSx0Lmdlb0NlbnRyb2lkPWZ1bmN0aW9uKHQpe3VwPWFwPWNwPXNwPWZw
PWxwPWhwPXBwPWRwPXZwPWdwPTAsdHIodCxHcCk7dmFyIG49ZHAsZT12cCxyPWdwLGk9bipuK2Uq
ZStyKnI7cmV0dXJuIGk8VHAmJihuPWxwLGU9aHAscj1wcCxhcDxNcCYmKG49Y3AsZT1zcCxyPWZw
KSwoaT1uKm4rZSplK3Iqcik8VHApP1tOYU4sTmFOXTpbUnAoZSxuKSpBcCxXZShyL1lwKGkpKSpB
cF19LHQuZ2VvQ2lyY2xlPWZ1bmN0aW9uKCl7ZnVuY3Rpb24gdCgpe3ZhciB0PXIuYXBwbHkodGhp
cyxhcmd1bWVudHMpLGE9aS5hcHBseSh0aGlzLGFyZ3VtZW50cykqQ3AsYz1vLmFwcGx5KHRoaXMs
YXJndW1lbnRzKSpDcDtyZXR1cm4gbj1bXSxlPXFyKC10WzBdKkNwLC10WzFdKkNwLDApLmludmVy
dCxJcih1LGEsYywxKSx0PXt0eXBlOiJQb2x5Z29uIixjb29yZGluYXRlczpbbl19LG49ZT1udWxs
LHR9dmFyIG4sZSxyPVByKFswLDBdKSxpPVByKDkwKSxvPVByKDYpLHU9e3BvaW50OmZ1bmN0aW9u
KHQscil7bi5wdXNoKHQ9ZSh0LHIpKSx0WzBdKj1BcCx0WzFdKj1BcH19O3JldHVybiB0LmNlbnRl
cj1mdW5jdGlvbihuKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8ocj0iZnVuY3Rpb24iPT10eXBl
b2Ygbj9uOlByKFsrblswXSwrblsxXV0pLHQpOnJ9LHQucmFkaXVzPWZ1bmN0aW9uKG4pe3JldHVy
biBhcmd1bWVudHMubGVuZ3RoPyhpPSJmdW5jdGlvbiI9PXR5cGVvZiBuP246UHIoK24pLHQpOml9
LHQucHJlY2lzaW9uPWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhvPSJmdW5j
dGlvbiI9PXR5cGVvZiBuP246UHIoK24pLHQpOm99LHR9LHQuZ2VvQ2xpcEFudGltZXJpZGlhbj1z
ZCx0Lmdlb0NsaXBDaXJjbGU9UXIsdC5nZW9DbGlwRXh0ZW50PWZ1bmN0aW9uKCl7dmFyIHQsbixl
LHI9MCxpPTAsbz05NjAsdT01MDA7cmV0dXJuIGU9e3N0cmVhbTpmdW5jdGlvbihlKXtyZXR1cm4g
dCYmbj09PWU/dDp0PUpyKHIsaSxvLHUpKG49ZSl9LGV4dGVudDpmdW5jdGlvbihhKXtyZXR1cm4g
YXJndW1lbnRzLmxlbmd0aD8ocj0rYVswXVswXSxpPSthWzBdWzFdLG89K2FbMV1bMF0sdT0rYVsx
XVsxXSx0PW49bnVsbCxlKTpbW3IsaV0sW28sdV1dfX19LHQuZ2VvQ2xpcFJlY3RhbmdsZT1Kcix0
Lmdlb0NvbnRhaW5zPWZ1bmN0aW9uKHQsbil7cmV0dXJuKHQmJmdkLmhhc093blByb3BlcnR5KHQu
dHlwZSk/Z2RbdC50eXBlXTppaSkodCxuKX0sdC5nZW9EaXN0YW5jZT1yaSx0Lmdlb0dyYXRpY3Vs
ZT1oaSx0Lmdlb0dyYXRpY3VsZTEwPWZ1bmN0aW9uKCl7cmV0dXJuIGhpKCkoKX0sdC5nZW9JbnRl
cnBvbGF0ZT1mdW5jdGlvbih0LG4pe3ZhciBlPXRbMF0qQ3Ascj10WzFdKkNwLGk9blswXSpDcCxv
PW5bMV0qQ3AsdT1McChyKSxhPUZwKHIpLGM9THAobykscz1GcChvKSxmPXUqTHAoZSksbD11KkZw
KGUpLGg9YypMcChpKSxwPWMqRnAoaSksZD0yKldlKFlwKFplKG8tcikrdSpjKlplKGktZSkpKSx2
PUZwKGQpLGc9ZD9mdW5jdGlvbih0KXt2YXIgbj1GcCh0Kj1kKS92LGU9RnAoZC10KS92LHI9ZSpm
K24qaCxpPWUqbCtuKnAsbz1lKmErbipzO3JldHVybltScChpLHIpKkFwLFJwKG8sWXAocipyK2kq
aSkpKkFwXX06ZnVuY3Rpb24oKXtyZXR1cm5bZSpBcCxyKkFwXX07cmV0dXJuIGcuZGlzdGFuY2U9
ZCxnfSx0Lmdlb0xlbmd0aD1laSx0Lmdlb1BhdGg9ZnVuY3Rpb24odCxuKXtmdW5jdGlvbiBlKHQp
e3JldHVybiB0JiYoImZ1bmN0aW9uIj09dHlwZW9mIG8mJmkucG9pbnRSYWRpdXMoK28uYXBwbHko
dGhpcyxhcmd1bWVudHMpKSx0cih0LHIoaSkpKSxpLnJlc3VsdCgpfXZhciByLGksbz00LjU7cmV0
dXJuIGUuYXJlYT1mdW5jdGlvbih0KXtyZXR1cm4gdHIodCxyKHhkKSkseGQucmVzdWx0KCl9LGUu
bWVhc3VyZT1mdW5jdGlvbih0KXtyZXR1cm4gdHIodCxyKEJkKSksQmQucmVzdWx0KCl9LGUuYm91
bmRzPWZ1bmN0aW9uKHQpe3JldHVybiB0cih0LHIoTmQpKSxOZC5yZXN1bHQoKX0sZS5jZW50cm9p
ZD1mdW5jdGlvbih0KXtyZXR1cm4gdHIodCxyKHFkKSkscWQucmVzdWx0KCl9LGUucHJvamVjdGlv
bj1mdW5jdGlvbihuKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8ocj1udWxsPT1uPyh0PW51bGws
cGkpOih0PW4pLnN0cmVhbSxlKTp0fSxlLmNvbnRleHQ9ZnVuY3Rpb24odCl7cmV0dXJuIGFyZ3Vt
ZW50cy5sZW5ndGg/KGk9bnVsbD09dD8obj1udWxsLG5ldyBDaSk6bmV3IFNpKG49dCksImZ1bmN0
aW9uIiE9dHlwZW9mIG8mJmkucG9pbnRSYWRpdXMobyksZSk6bn0sZS5wb2ludFJhZGl1cz1mdW5j
dGlvbih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8obz0iZnVuY3Rpb24iPT10eXBlb2YgdD90
OihpLnBvaW50UmFkaXVzKCt0KSwrdCksZSk6b30sZS5wcm9qZWN0aW9uKHQpLmNvbnRleHQobil9
LHQuZ2VvQWxiZXJzPVhpLHQuZ2VvQWxiZXJzVXNhPWZ1bmN0aW9uKCl7ZnVuY3Rpb24gdCh0KXt2
YXIgbj10WzBdLGU9dFsxXTtyZXR1cm4gYT1udWxsLGkucG9pbnQobixlKSxhfHwoby5wb2ludChu
LGUpLGEpfHwodS5wb2ludChuLGUpLGEpfWZ1bmN0aW9uIG4oKXtyZXR1cm4gZT1yPW51bGwsdH12
YXIgZSxyLGksbyx1LGEsYz1YaSgpLHM9amkoKS5yb3RhdGUoWzE1NCwwXSkuY2VudGVyKFstMiw1
OC41XSkucGFyYWxsZWxzKFs1NSw2NV0pLGY9amkoKS5yb3RhdGUoWzE1NywwXSkuY2VudGVyKFst
MywxOS45XSkucGFyYWxsZWxzKFs4LDE4XSksbD17cG9pbnQ6ZnVuY3Rpb24odCxuKXthPVt0LG5d
fX07cmV0dXJuIHQuaW52ZXJ0PWZ1bmN0aW9uKHQpe3ZhciBuPWMuc2NhbGUoKSxlPWMudHJhbnNs
YXRlKCkscj0odFswXS1lWzBdKS9uLGk9KHRbMV0tZVsxXSkvbjtyZXR1cm4oaT49LjEyJiZpPC4y
MzQmJnI+PS0uNDI1JiZyPC0uMjE0P3M6aT49LjE2NiYmaTwuMjM0JiZyPj0tLjIxNCYmcjwtLjEx
NT9mOmMpLmludmVydCh0KX0sdC5zdHJlYW09ZnVuY3Rpb24odCl7cmV0dXJuIGUmJnI9PT10P2U6
ZT1mdW5jdGlvbih0KXt2YXIgbj10Lmxlbmd0aDtyZXR1cm57cG9pbnQ6ZnVuY3Rpb24oZSxyKXtm
b3IodmFyIGk9LTE7KytpPG47KXRbaV0ucG9pbnQoZSxyKX0sc3BoZXJlOmZ1bmN0aW9uKCl7Zm9y
KHZhciBlPS0xOysrZTxuOyl0W2VdLnNwaGVyZSgpfSxsaW5lU3RhcnQ6ZnVuY3Rpb24oKXtmb3Io
dmFyIGU9LTE7KytlPG47KXRbZV0ubGluZVN0YXJ0KCl9LGxpbmVFbmQ6ZnVuY3Rpb24oKXtmb3Io
dmFyIGU9LTE7KytlPG47KXRbZV0ubGluZUVuZCgpfSxwb2x5Z29uU3RhcnQ6ZnVuY3Rpb24oKXtm
b3IodmFyIGU9LTE7KytlPG47KXRbZV0ucG9seWdvblN0YXJ0KCl9LHBvbHlnb25FbmQ6ZnVuY3Rp
b24oKXtmb3IodmFyIGU9LTE7KytlPG47KXRbZV0ucG9seWdvbkVuZCgpfX19KFtjLnN0cmVhbShy
PXQpLHMuc3RyZWFtKHQpLGYuc3RyZWFtKHQpXSl9LHQucHJlY2lzaW9uPWZ1bmN0aW9uKHQpe3Jl
dHVybiBhcmd1bWVudHMubGVuZ3RoPyhjLnByZWNpc2lvbih0KSxzLnByZWNpc2lvbih0KSxmLnBy
ZWNpc2lvbih0KSxuKCkpOmMucHJlY2lzaW9uKCl9LHQuc2NhbGU9ZnVuY3Rpb24obil7cmV0dXJu
IGFyZ3VtZW50cy5sZW5ndGg/KGMuc2NhbGUobikscy5zY2FsZSguMzUqbiksZi5zY2FsZShuKSx0
LnRyYW5zbGF0ZShjLnRyYW5zbGF0ZSgpKSk6Yy5zY2FsZSgpfSx0LnRyYW5zbGF0ZT1mdW5jdGlv
bih0KXtpZighYXJndW1lbnRzLmxlbmd0aClyZXR1cm4gYy50cmFuc2xhdGUoKTt2YXIgZT1jLnNj
YWxlKCkscj0rdFswXSxhPSt0WzFdO3JldHVybiBpPWMudHJhbnNsYXRlKHQpLmNsaXBFeHRlbnQo
W1tyLS40NTUqZSxhLS4yMzgqZV0sW3IrLjQ1NSplLGErLjIzOCplXV0pLnN0cmVhbShsKSxvPXMu
dHJhbnNsYXRlKFtyLS4zMDcqZSxhKy4yMDEqZV0pLmNsaXBFeHRlbnQoW1tyLS40MjUqZStNcCxh
Ky4xMiplK01wXSxbci0uMjE0KmUtTXAsYSsuMjM0KmUtTXBdXSkuc3RyZWFtKGwpLHU9Zi50cmFu
c2xhdGUoW3ItLjIwNSplLGErLjIxMiplXSkuY2xpcEV4dGVudChbW3ItLjIxNCplK01wLGErLjE2
NiplK01wXSxbci0uMTE1KmUtTXAsYSsuMjM0KmUtTXBdXSkuc3RyZWFtKGwpLG4oKX0sdC5maXRF
eHRlbnQ9ZnVuY3Rpb24obixlKXtyZXR1cm4gcWkodCxuLGUpfSx0LmZpdFNpemU9ZnVuY3Rpb24o
bixlKXtyZXR1cm4gRGkodCxuLGUpfSx0LmZpdFdpZHRoPWZ1bmN0aW9uKG4sZSl7cmV0dXJuIFVp
KHQsbixlKX0sdC5maXRIZWlnaHQ9ZnVuY3Rpb24obixlKXtyZXR1cm4gT2kodCxuLGUpfSx0LnNj
YWxlKDEwNzApfSx0Lmdlb0F6aW11dGhhbEVxdWFsQXJlYT1mdW5jdGlvbigpe3JldHVybiBJaShW
ZCkuc2NhbGUoMTI0Ljc1KS5jbGlwQW5nbGUoMTc5Ljk5OSl9LHQuZ2VvQXppbXV0aGFsRXF1YWxB
cmVhUmF3PVZkLHQuZ2VvQXppbXV0aGFsRXF1aWRpc3RhbnQ9ZnVuY3Rpb24oKXtyZXR1cm4gSWko
JGQpLnNjYWxlKDc5LjQxODgpLmNsaXBBbmdsZSgxNzkuOTk5KX0sdC5nZW9BemltdXRoYWxFcXVp
ZGlzdGFudFJhdz0kZCx0Lmdlb0NvbmljQ29uZm9ybWFsPWZ1bmN0aW9uKCl7cmV0dXJuIEJpKFFp
KS5zY2FsZSgxMDkuNSkucGFyYWxsZWxzKFszMCwzMF0pfSx0Lmdlb0NvbmljQ29uZm9ybWFsUmF3
PVFpLHQuZ2VvQ29uaWNFcXVhbEFyZWE9amksdC5nZW9Db25pY0VxdWFsQXJlYVJhdz1IaSx0Lmdl
b0NvbmljRXF1aWRpc3RhbnQ9ZnVuY3Rpb24oKXtyZXR1cm4gQmkoS2kpLnNjYWxlKDEzMS4xNTQp
LmNlbnRlcihbMCwxMy45Mzg5XSl9LHQuZ2VvQ29uaWNFcXVpZGlzdGFudFJhdz1LaSx0Lmdlb0Vx
dWlyZWN0YW5ndWxhcj1mdW5jdGlvbigpe3JldHVybiBJaShKaSkuc2NhbGUoMTUyLjYzKX0sdC5n
ZW9FcXVpcmVjdGFuZ3VsYXJSYXc9SmksdC5nZW9Hbm9tb25pYz1mdW5jdGlvbigpe3JldHVybiBJ
aSh0bykuc2NhbGUoMTQ0LjA0OSkuY2xpcEFuZ2xlKDYwKX0sdC5nZW9Hbm9tb25pY1Jhdz10byx0
Lmdlb0lkZW50aXR5PWZ1bmN0aW9uKCl7ZnVuY3Rpb24gdCgpe3JldHVybiBpPW89bnVsbCx1fXZh
ciBuLGUscixpLG8sdSxhPTEsYz0wLHM9MCxmPTEsbD0xLGg9cGkscD1udWxsLGQ9cGk7cmV0dXJu
IHU9e3N0cmVhbTpmdW5jdGlvbih0KXtyZXR1cm4gaSYmbz09PXQ/aTppPWgoZChvPXQpKX0scG9z
dGNsaXA6ZnVuY3Rpb24oaSl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KGQ9aSxwPW49ZT1yPW51
bGwsdCgpKTpkfSxjbGlwRXh0ZW50OmZ1bmN0aW9uKGkpe3JldHVybiBhcmd1bWVudHMubGVuZ3Ro
PyhkPW51bGw9PWk/KHA9bj1lPXI9bnVsbCxwaSk6SnIocD0raVswXVswXSxuPStpWzBdWzFdLGU9
K2lbMV1bMF0scj0raVsxXVsxXSksdCgpKTpudWxsPT1wP251bGw6W1twLG5dLFtlLHJdXX0sc2Nh
bGU6ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KGg9bm8oKGE9K24pKmYsYSps
LGMscyksdCgpKTphfSx0cmFuc2xhdGU6ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5sZW5n
dGg/KGg9bm8oYSpmLGEqbCxjPStuWzBdLHM9K25bMV0pLHQoKSk6W2Msc119LHJlZmxlY3RYOmZ1
bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhoPW5vKGEqKGY9bj8tMToxKSxhKmws
YyxzKSx0KCkpOmY8MH0scmVmbGVjdFk6ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5sZW5n
dGg/KGg9bm8oYSpmLGEqKGw9bj8tMToxKSxjLHMpLHQoKSk6bDwwfSxmaXRFeHRlbnQ6ZnVuY3Rp
b24odCxuKXtyZXR1cm4gcWkodSx0LG4pfSxmaXRTaXplOmZ1bmN0aW9uKHQsbil7cmV0dXJuIERp
KHUsdCxuKX0sZml0V2lkdGg6ZnVuY3Rpb24odCxuKXtyZXR1cm4gVWkodSx0LG4pfSxmaXRIZWln
aHQ6ZnVuY3Rpb24odCxuKXtyZXR1cm4gT2kodSx0LG4pfX19LHQuZ2VvUHJvamVjdGlvbj1JaSx0
Lmdlb1Byb2plY3Rpb25NdXRhdG9yPVlpLHQuZ2VvTWVyY2F0b3I9ZnVuY3Rpb24oKXtyZXR1cm4g
WmkoV2kpLnNjYWxlKDk2MS9FcCl9LHQuZ2VvTWVyY2F0b3JSYXc9V2ksdC5nZW9OYXR1cmFsRWFy
dGgxPWZ1bmN0aW9uKCl7cmV0dXJuIElpKGVvKS5zY2FsZSgxNzUuMjk1KX0sdC5nZW9OYXR1cmFs
RWFydGgxUmF3PWVvLHQuZ2VvT3J0aG9ncmFwaGljPWZ1bmN0aW9uKCl7cmV0dXJuIElpKHJvKS5z
Y2FsZSgyNDkuNSkuY2xpcEFuZ2xlKDkwK01wKX0sdC5nZW9PcnRob2dyYXBoaWNSYXc9cm8sdC5n
ZW9TdGVyZW9ncmFwaGljPWZ1bmN0aW9uKCl7cmV0dXJuIElpKGlvKS5zY2FsZSgyNTApLmNsaXBB
bmdsZSgxNDIpfSx0Lmdlb1N0ZXJlb2dyYXBoaWNSYXc9aW8sdC5nZW9UcmFuc3ZlcnNlTWVyY2F0
b3I9ZnVuY3Rpb24oKXt2YXIgdD1aaShvbyksbj10LmNlbnRlcixlPXQucm90YXRlO3JldHVybiB0
LmNlbnRlcj1mdW5jdGlvbih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD9uKFstdFsxXSx0WzBd
XSk6KHQ9bigpLFt0WzFdLC10WzBdXSl9LHQucm90YXRlPWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1
bWVudHMubGVuZ3RoP2UoW3RbMF0sdFsxXSx0Lmxlbmd0aD4yP3RbMl0rOTA6OTBdKToodD1lKCks
W3RbMF0sdFsxXSx0WzJdLTkwXSl9LGUoWzAsMCw5MF0pLnNjYWxlKDE1OS4xNTUpfSx0Lmdlb1Ry
YW5zdmVyc2VNZXJjYXRvclJhdz1vbyx0Lmdlb1JvdGF0aW9uPUZyLHQuZ2VvU3RyZWFtPXRyLHQu
Z2VvVHJhbnNmb3JtPWZ1bmN0aW9uKHQpe3JldHVybntzdHJlYW06UGkodCl9fSx0LmNsdXN0ZXI9
ZnVuY3Rpb24oKXtmdW5jdGlvbiB0KHQpe3ZhciBvLHU9MDt0LmVhY2hBZnRlcihmdW5jdGlvbih0
KXt2YXIgZT10LmNoaWxkcmVuO2U/KHQueD1mdW5jdGlvbih0KXtyZXR1cm4gdC5yZWR1Y2UoYW8s
MCkvdC5sZW5ndGh9KGUpLHQueT1mdW5jdGlvbih0KXtyZXR1cm4gMSt0LnJlZHVjZShjbywwKX0o
ZSkpOih0Lng9bz91Kz1uKHQsbyk6MCx0Lnk9MCxvPXQpfSk7dmFyIGE9ZnVuY3Rpb24odCl7Zm9y
KHZhciBuO249dC5jaGlsZHJlbjspdD1uWzBdO3JldHVybiB0fSh0KSxjPWZ1bmN0aW9uKHQpe2Zv
cih2YXIgbjtuPXQuY2hpbGRyZW47KXQ9bltuLmxlbmd0aC0xXTtyZXR1cm4gdH0odCkscz1hLngt
bihhLGMpLzIsZj1jLngrbihjLGEpLzI7cmV0dXJuIHQuZWFjaEFmdGVyKGk/ZnVuY3Rpb24obil7
bi54PShuLngtdC54KSplLG4ueT0odC55LW4ueSkqcn06ZnVuY3Rpb24obil7bi54PShuLngtcykv
KGYtcykqZSxuLnk9KDEtKHQueT9uLnkvdC55OjEpKSpyfSl9dmFyIG49dW8sZT0xLHI9MSxpPSEx
O3JldHVybiB0LnNlcGFyYXRpb249ZnVuY3Rpb24oZSl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/
KG49ZSx0KTpufSx0LnNpemU9ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KGk9
ITEsZT0rblswXSxyPStuWzFdLHQpOmk/bnVsbDpbZSxyXX0sdC5ub2RlU2l6ZT1mdW5jdGlvbihu
KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oaT0hMCxlPStuWzBdLHI9K25bMV0sdCk6aT9bZSxy
XTpudWxsfSx0fSx0LmhpZXJhcmNoeT1mbyx0LnBhY2s9ZnVuY3Rpb24oKXtmdW5jdGlvbiB0KHQp
e3JldHVybiB0Lng9ZS8yLHQueT1yLzIsbj90LmVhY2hCZWZvcmUoem8obikpLmVhY2hBZnRlcihQ
byhpLC41KSkuZWFjaEJlZm9yZShSbygxKSk6dC5lYWNoQmVmb3JlKHpvKENvKSkuZWFjaEFmdGVy
KFBvKEVvLDEpKS5lYWNoQWZ0ZXIoUG8oaSx0LnIvTWF0aC5taW4oZSxyKSkpLmVhY2hCZWZvcmUo
Um8oTWF0aC5taW4oZSxyKS8oMip0LnIpKSksdH12YXIgbj1udWxsLGU9MSxyPTEsaT1FbztyZXR1
cm4gdC5yYWRpdXM9ZnVuY3Rpb24oZSl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KG49ZnVuY3Rp
b24odCl7cmV0dXJuIG51bGw9PXQ/bnVsbDpTbyh0KX0oZSksdCk6bn0sdC5zaXplPWZ1bmN0aW9u
KG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhlPStuWzBdLHI9K25bMV0sdCk6W2Uscl19LHQu
cGFkZGluZz1mdW5jdGlvbihuKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oaT0iZnVuY3Rpb24i
PT10eXBlb2Ygbj9uOkFvKCtuKSx0KTppfSx0fSx0LnBhY2tTaWJsaW5ncz1mdW5jdGlvbih0KXty
ZXR1cm4ga28odCksdH0sdC5wYWNrRW5jbG9zZT1nbyx0LnBhcnRpdGlvbj1mdW5jdGlvbigpe2Z1
bmN0aW9uIHQodCl7dmFyIG89dC5oZWlnaHQrMTtyZXR1cm4gdC54MD10LnkwPXIsdC54MT1uLHQu
eTE9ZS9vLHQuZWFjaEJlZm9yZShmdW5jdGlvbih0LG4pe3JldHVybiBmdW5jdGlvbihlKXtlLmNo
aWxkcmVuJiZxbyhlLGUueDAsdCooZS5kZXB0aCsxKS9uLGUueDEsdCooZS5kZXB0aCsyKS9uKTt2
YXIgaT1lLngwLG89ZS55MCx1PWUueDEtcixhPWUueTEtcjt1PGkmJihpPXU9KGkrdSkvMiksYTxv
JiYobz1hPShvK2EpLzIpLGUueDA9aSxlLnkwPW8sZS54MT11LGUueTE9YX19KGUsbykpLGkmJnQu
ZWFjaEJlZm9yZShMbyksdH12YXIgbj0xLGU9MSxyPTAsaT0hMTtyZXR1cm4gdC5yb3VuZD1mdW5j
dGlvbihuKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oaT0hIW4sdCk6aX0sdC5zaXplPWZ1bmN0
aW9uKHIpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhuPStyWzBdLGU9K3JbMV0sdCk6W24sZV19
LHQucGFkZGluZz1mdW5jdGlvbihuKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8ocj0rbix0KTpy
fSx0fSx0LnN0cmF0aWZ5PWZ1bmN0aW9uKCl7ZnVuY3Rpb24gdCh0KXt2YXIgcixpLG8sdSxhLGMs
cyxmPXQubGVuZ3RoLGw9bmV3IEFycmF5KGYpLGg9e307Zm9yKGk9MDtpPGY7KytpKXI9dFtpXSxh
PWxbaV09bmV3IHZvKHIpLG51bGwhPShjPW4ocixpLHQpKSYmKGMrPSIiKSYmKGhbcz1aZCsoYS5p
ZD1jKV09cyBpbiBoP1FkOmEpO2ZvcihpPTA7aTxmOysraSlpZihhPWxbaV0sbnVsbCE9KGM9ZSh0
W2ldLGksdCkpJiYoYys9IiIpKXtpZighKHU9aFtaZCtjXSkpdGhyb3cgbmV3IEVycm9yKCJtaXNz
aW5nOiAiK2MpO2lmKHU9PT1RZCl0aHJvdyBuZXcgRXJyb3IoImFtYmlndW91czogIitjKTt1LmNo
aWxkcmVuP3UuY2hpbGRyZW4ucHVzaChhKTp1LmNoaWxkcmVuPVthXSxhLnBhcmVudD11fWVsc2V7
aWYobyl0aHJvdyBuZXcgRXJyb3IoIm11bHRpcGxlIHJvb3RzIik7bz1hfWlmKCFvKXRocm93IG5l
dyBFcnJvcigibm8gcm9vdCIpO2lmKG8ucGFyZW50PUdkLG8uZWFjaEJlZm9yZShmdW5jdGlvbih0
KXt0LmRlcHRoPXQucGFyZW50LmRlcHRoKzEsLS1mfSkuZWFjaEJlZm9yZShwbyksby5wYXJlbnQ9
bnVsbCxmPjApdGhyb3cgbmV3IEVycm9yKCJjeWNsZSIpO3JldHVybiBvfXZhciBuPURvLGU9VW87
cmV0dXJuIHQuaWQ9ZnVuY3Rpb24oZSl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KG49U28oZSks
dCk6bn0sdC5wYXJlbnRJZD1mdW5jdGlvbihuKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oZT1T
byhuKSx0KTplfSx0fSx0LnRyZWU9ZnVuY3Rpb24oKXtmdW5jdGlvbiB0KHQpe3ZhciBjPWZ1bmN0
aW9uKHQpe2Zvcih2YXIgbixlLHIsaSxvLHU9bmV3IEhvKHQsMCksYT1bdV07bj1hLnBvcCgpOylp
ZihyPW4uXy5jaGlsZHJlbilmb3Iobi5jaGlsZHJlbj1uZXcgQXJyYXkobz1yLmxlbmd0aCksaT1v
LTE7aT49MDstLWkpYS5wdXNoKGU9bi5jaGlsZHJlbltpXT1uZXcgSG8ocltpXSxpKSksZS5wYXJl
bnQ9bjtyZXR1cm4odS5wYXJlbnQ9bmV3IEhvKG51bGwsMCkpLmNoaWxkcmVuPVt1XSx1fSh0KTtp
ZihjLmVhY2hBZnRlcihuKSxjLnBhcmVudC5tPS1jLnosYy5lYWNoQmVmb3JlKGUpLGEpdC5lYWNo
QmVmb3JlKHIpO2Vsc2V7dmFyIHM9dCxmPXQsbD10O3QuZWFjaEJlZm9yZShmdW5jdGlvbih0KXt0
Lng8cy54JiYocz10KSx0Lng+Zi54JiYoZj10KSx0LmRlcHRoPmwuZGVwdGgmJihsPXQpfSk7dmFy
IGg9cz09PWY/MTppKHMsZikvMixwPWgtcy54LGQ9by8oZi54K2grcCksdj11LyhsLmRlcHRofHwx
KTt0LmVhY2hCZWZvcmUoZnVuY3Rpb24odCl7dC54PSh0LngrcCkqZCx0Lnk9dC5kZXB0aCp2fSl9
cmV0dXJuIHR9ZnVuY3Rpb24gbih0KXt2YXIgbj10LmNoaWxkcmVuLGU9dC5wYXJlbnQuY2hpbGRy
ZW4scj10Lmk/ZVt0LmktMV06bnVsbDtpZihuKXsoZnVuY3Rpb24odCl7Zm9yKHZhciBuLGU9MCxy
PTAsaT10LmNoaWxkcmVuLG89aS5sZW5ndGg7LS1vPj0wOykobj1pW29dKS56Kz1lLG4ubSs9ZSxl
Kz1uLnMrKHIrPW4uYyl9KSh0KTt2YXIgbz0oblswXS56K25bbi5sZW5ndGgtMV0ueikvMjtyPyh0
Lno9ci56K2kodC5fLHIuXyksdC5tPXQuei1vKTp0Lno9b31lbHNlIHImJih0Lno9ci56K2kodC5f
LHIuXykpO3QucGFyZW50LkE9ZnVuY3Rpb24odCxuLGUpe2lmKG4pe2Zvcih2YXIgcixvPXQsdT10
LGE9bixjPW8ucGFyZW50LmNoaWxkcmVuWzBdLHM9by5tLGY9dS5tLGw9YS5tLGg9Yy5tO2E9SW8o
YSksbz1GbyhvKSxhJiZvOyljPUZvKGMpLCh1PUlvKHUpKS5hPXQsKHI9YS56K2wtby56LXMraShh
Ll8sby5fKSk+MCYmKFlvKEJvKGEsdCxlKSx0LHIpLHMrPXIsZis9ciksbCs9YS5tLHMrPW8ubSxo
Kz1jLm0sZis9dS5tO2EmJiFJbyh1KSYmKHUudD1hLHUubSs9bC1mKSxvJiYhRm8oYykmJihjLnQ9
byxjLm0rPXMtaCxlPXQpfXJldHVybiBlfSh0LHIsdC5wYXJlbnQuQXx8ZVswXSl9ZnVuY3Rpb24g
ZSh0KXt0Ll8ueD10LnordC5wYXJlbnQubSx0Lm0rPXQucGFyZW50Lm19ZnVuY3Rpb24gcih0KXt0
LngqPW8sdC55PXQuZGVwdGgqdX12YXIgaT1PbyxvPTEsdT0xLGE9bnVsbDtyZXR1cm4gdC5zZXBh
cmF0aW9uPWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhpPW4sdCk6aX0sdC5z
aXplPWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhhPSExLG89K25bMF0sdT0r
blsxXSx0KTphP251bGw6W28sdV19LHQubm9kZVNpemU9ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3Vt
ZW50cy5sZW5ndGg/KGE9ITAsbz0rblswXSx1PStuWzFdLHQpOmE/W28sdV06bnVsbH0sdH0sdC50
cmVlbWFwPWZ1bmN0aW9uKCl7ZnVuY3Rpb24gdCh0KXtyZXR1cm4gdC54MD10LnkwPTAsdC54MT1p
LHQueTE9byx0LmVhY2hCZWZvcmUobiksdT1bMF0sciYmdC5lYWNoQmVmb3JlKExvKSx0fWZ1bmN0
aW9uIG4odCl7dmFyIG49dVt0LmRlcHRoXSxyPXQueDArbixpPXQueTArbixvPXQueDEtbixoPXQu
eTEtbjtvPHImJihyPW89KHIrbykvMiksaDxpJiYoaT1oPShpK2gpLzIpLHQueDA9cix0LnkwPWks
dC54MT1vLHQueTE9aCx0LmNoaWxkcmVuJiYobj11W3QuZGVwdGgrMV09YSh0KS8yLHIrPWwodCkt
bixpKz1jKHQpLW4sby09cyh0KS1uLGgtPWYodCktbixvPHImJihyPW89KHIrbykvMiksaDxpJiYo
aT1oPShpK2gpLzIpLGUodCxyLGksbyxoKSl9dmFyIGU9S2Qscj0hMSxpPTEsbz0xLHU9WzBdLGE9
RW8sYz1FbyxzPUVvLGY9RW8sbD1FbztyZXR1cm4gdC5yb3VuZD1mdW5jdGlvbihuKXtyZXR1cm4g
YXJndW1lbnRzLmxlbmd0aD8ocj0hIW4sdCk6cn0sdC5zaXplPWZ1bmN0aW9uKG4pe3JldHVybiBh
cmd1bWVudHMubGVuZ3RoPyhpPStuWzBdLG89K25bMV0sdCk6W2ksb119LHQudGlsZT1mdW5jdGlv
bihuKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oZT1TbyhuKSx0KTplfSx0LnBhZGRpbmc9ZnVu
Y3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/dC5wYWRkaW5nSW5uZXIobikucGFkZGlu
Z091dGVyKG4pOnQucGFkZGluZ0lubmVyKCl9LHQucGFkZGluZ0lubmVyPWZ1bmN0aW9uKG4pe3Jl
dHVybiBhcmd1bWVudHMubGVuZ3RoPyhhPSJmdW5jdGlvbiI9PXR5cGVvZiBuP246QW8oK24pLHQp
OmF9LHQucGFkZGluZ091dGVyPWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoP3Qu
cGFkZGluZ1RvcChuKS5wYWRkaW5nUmlnaHQobikucGFkZGluZ0JvdHRvbShuKS5wYWRkaW5nTGVm
dChuKTp0LnBhZGRpbmdUb3AoKX0sdC5wYWRkaW5nVG9wPWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1
bWVudHMubGVuZ3RoPyhjPSJmdW5jdGlvbiI9PXR5cGVvZiBuP246QW8oK24pLHQpOmN9LHQucGFk
ZGluZ1JpZ2h0PWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhzPSJmdW5jdGlv
biI9PXR5cGVvZiBuP246QW8oK24pLHQpOnN9LHQucGFkZGluZ0JvdHRvbT1mdW5jdGlvbihuKXty
ZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oZj0iZnVuY3Rpb24iPT10eXBlb2Ygbj9uOkFvKCtuKSx0
KTpmfSx0LnBhZGRpbmdMZWZ0PWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhs
PSJmdW5jdGlvbiI9PXR5cGVvZiBuP246QW8oK24pLHQpOmx9LHR9LHQudHJlZW1hcEJpbmFyeT1m
dW5jdGlvbih0LG4sZSxyLGkpe2Z1bmN0aW9uIG8odCxuLGUscixpLHUsYSl7aWYodD49bi0xKXt2
YXIgcz1jW3RdO3JldHVybiBzLngwPXIscy55MD1pLHMueDE9dSx2b2lkKHMueTE9YSl9Zm9yKHZh
ciBsPWZbdF0saD1lLzIrbCxwPXQrMSxkPW4tMTtwPGQ7KXt2YXIgdj1wK2Q+Pj4xO2Zbdl08aD9w
PXYrMTpkPXZ9aC1mW3AtMV08ZltwXS1oJiZ0KzE8cCYmLS1wO3ZhciBnPWZbcF0tbCxfPWUtZztp
Zih1LXI+YS1pKXt2YXIgeT0ocipfK3UqZykvZTtvKHQscCxnLHIsaSx5LGEpLG8ocCxuLF8seSxp
LHUsYSl9ZWxzZXt2YXIgbT0oaSpfK2EqZykvZTtvKHQscCxnLHIsaSx1LG0pLG8ocCxuLF8scixt
LHUsYSl9fXZhciB1LGEsYz10LmNoaWxkcmVuLHM9Yy5sZW5ndGgsZj1uZXcgQXJyYXkocysxKTtm
b3IoZlswXT1hPXU9MDt1PHM7Kyt1KWZbdSsxXT1hKz1jW3VdLnZhbHVlO28oMCxzLHQudmFsdWUs
bixlLHIsaSl9LHQudHJlZW1hcERpY2U9cW8sdC50cmVlbWFwU2xpY2U9am8sdC50cmVlbWFwU2xp
Y2VEaWNlPWZ1bmN0aW9uKHQsbixlLHIsaSl7KDEmdC5kZXB0aD9qbzpxbykodCxuLGUscixpKX0s
dC50cmVlbWFwU3F1YXJpZnk9S2QsdC50cmVlbWFwUmVzcXVhcmlmeT10dix0LmludGVycG9sYXRl
PWZuLHQuaW50ZXJwb2xhdGVBcnJheT1vbix0LmludGVycG9sYXRlQmFzaXM9R3QsdC5pbnRlcnBv
bGF0ZUJhc2lzQ2xvc2VkPVF0LHQuaW50ZXJwb2xhdGVEYXRlPXVuLHQuaW50ZXJwb2xhdGVOdW1i
ZXI9YW4sdC5pbnRlcnBvbGF0ZU9iamVjdD1jbix0LmludGVycG9sYXRlUm91bmQ9bG4sdC5pbnRl
cnBvbGF0ZVN0cmluZz1zbix0LmludGVycG9sYXRlVHJhbnNmb3JtQ3NzPUdmLHQuaW50ZXJwb2xh
dGVUcmFuc2Zvcm1Tdmc9UWYsdC5pbnRlcnBvbGF0ZVpvb209dm4sdC5pbnRlcnBvbGF0ZVJnYj1I
Zix0LmludGVycG9sYXRlUmdiQmFzaXM9amYsdC5pbnRlcnBvbGF0ZVJnYkJhc2lzQ2xvc2VkPVhm
LHQuaW50ZXJwb2xhdGVIc2w9ZWwsdC5pbnRlcnBvbGF0ZUhzbExvbmc9cmwsdC5pbnRlcnBvbGF0
ZUxhYj1mdW5jdGlvbih0LG4pe3ZhciBlPWVuKCh0PUZ0KHQpKS5sLChuPUZ0KG4pKS5sKSxyPWVu
KHQuYSxuLmEpLGk9ZW4odC5iLG4uYiksbz1lbih0Lm9wYWNpdHksbi5vcGFjaXR5KTtyZXR1cm4g
ZnVuY3Rpb24obil7cmV0dXJuIHQubD1lKG4pLHQuYT1yKG4pLHQuYj1pKG4pLHQub3BhY2l0eT1v
KG4pLHQrIiJ9fSx0LmludGVycG9sYXRlSGNsPWlsLHQuaW50ZXJwb2xhdGVIY2xMb25nPW9sLHQu
aW50ZXJwb2xhdGVDdWJlaGVsaXg9dWwsdC5pbnRlcnBvbGF0ZUN1YmVoZWxpeExvbmc9YWwsdC5x
dWFudGl6ZT1mdW5jdGlvbih0LG4pe2Zvcih2YXIgZT1uZXcgQXJyYXkobikscj0wO3I8bjsrK3Ip
ZVtyXT10KHIvKG4tMSkpO3JldHVybiBlfSx0LnBhdGg9ZWUsdC5wb2x5Z29uQXJlYT1mdW5jdGlv
bih0KXtmb3IodmFyIG4sZT0tMSxyPXQubGVuZ3RoLGk9dFtyLTFdLG89MDsrK2U8cjspbj1pLGk9
dFtlXSxvKz1uWzFdKmlbMF0tblswXSppWzFdO3JldHVybiBvLzJ9LHQucG9seWdvbkNlbnRyb2lk
PWZ1bmN0aW9uKHQpe2Zvcih2YXIgbixlLHI9LTEsaT10Lmxlbmd0aCxvPTAsdT0wLGE9dFtpLTFd
LGM9MDsrK3I8aTspbj1hLGE9dFtyXSxjKz1lPW5bMF0qYVsxXS1hWzBdKm5bMV0sbys9KG5bMF0r
YVswXSkqZSx1Kz0oblsxXSthWzFdKSplO3JldHVybiBjKj0zLFtvL2MsdS9jXX0sdC5wb2x5Z29u
SHVsbD1mdW5jdGlvbih0KXtpZigoZT10Lmxlbmd0aCk8MylyZXR1cm4gbnVsbDt2YXIgbixlLHI9
bmV3IEFycmF5KGUpLGk9bmV3IEFycmF5KGUpO2ZvcihuPTA7bjxlOysrbilyW25dPVsrdFtuXVsw
XSwrdFtuXVsxXSxuXTtmb3Ioci5zb3J0KCRvKSxuPTA7bjxlOysrbilpW25dPVtyW25dWzBdLC1y
W25dWzFdXTt2YXIgbz1XbyhyKSx1PVdvKGkpLGE9dVswXT09PW9bMF0sYz11W3UubGVuZ3RoLTFd
PT09b1tvLmxlbmd0aC0xXSxzPVtdO2ZvcihuPW8ubGVuZ3RoLTE7bj49MDstLW4pcy5wdXNoKHRb
cltvW25dXVsyXV0pO2ZvcihuPSthO248dS5sZW5ndGgtYzsrK24pcy5wdXNoKHRbclt1W25dXVsy
XV0pO3JldHVybiBzfSx0LnBvbHlnb25Db250YWlucz1mdW5jdGlvbih0LG4pe2Zvcih2YXIgZSxy
LGk9dC5sZW5ndGgsbz10W2ktMV0sdT1uWzBdLGE9blsxXSxjPW9bMF0scz1vWzFdLGY9ITEsbD0w
O2w8aTsrK2wpZT0obz10W2xdKVswXSwocj1vWzFdKT5hIT1zPmEmJnU8KGMtZSkqKGEtcikvKHMt
cikrZSYmKGY9IWYpLGM9ZSxzPXI7cmV0dXJuIGZ9LHQucG9seWdvbkxlbmd0aD1mdW5jdGlvbih0
KXtmb3IodmFyIG4sZSxyPS0xLGk9dC5sZW5ndGgsbz10W2ktMV0sdT1vWzBdLGE9b1sxXSxjPTA7
KytyPGk7KW49dSxlPWEsbi09dT0obz10W3JdKVswXSxlLT1hPW9bMV0sYys9TWF0aC5zcXJ0KG4q
bitlKmUpO3JldHVybiBjfSx0LnF1YWR0cmVlPVRlLHQucXVldWU9S28sdC5yYW5kb21Vbmlmb3Jt
PXJ2LHQucmFuZG9tTm9ybWFsPWl2LHQucmFuZG9tTG9nTm9ybWFsPW92LHQucmFuZG9tQmF0ZXM9
YXYsdC5yYW5kb21JcndpbkhhbGw9dXYsdC5yYW5kb21FeHBvbmVudGlhbD1jdix0LnJlcXVlc3Q9
bnUsdC5odG1sPXN2LHQuanNvbj1mdix0LnRleHQ9bHYsdC54bWw9aHYsdC5jc3Y9cHYsdC50c3Y9
ZHYsdC5zY2FsZUJhbmQ9b3UsdC5zY2FsZVBvaW50PWZ1bmN0aW9uKCl7cmV0dXJuIHV1KG91KCku
cGFkZGluZ0lubmVyKDEpKX0sdC5zY2FsZUlkZW50aXR5PWd1LHQuc2NhbGVMaW5lYXI9dnUsdC5z
Y2FsZUxvZz1UdSx0LnNjYWxlT3JkaW5hbD1pdSx0LnNjYWxlSW1wbGljaXQ9eXYsdC5zY2FsZVBv
dz1rdSx0LnNjYWxlU3FydD1mdW5jdGlvbigpe3JldHVybiBrdSgpLmV4cG9uZW50KC41KX0sdC5z
Y2FsZVF1YW50aWxlPVN1LHQuc2NhbGVRdWFudGl6ZT1FdSx0LnNjYWxlVGhyZXNob2xkPUF1LHQu
c2NhbGVUaW1lPWZ1bmN0aW9uKCl7cmV0dXJuIFZhKEd2LFd2LEx2LFB2LEN2LEV2LGt2LHd2LHQu
dGltZUZvcm1hdCkuZG9tYWluKFtuZXcgRGF0ZSgyZTMsMCwxKSxuZXcgRGF0ZSgyZTMsMCwyKV0p
fSx0LnNjYWxlVXRjPWZ1bmN0aW9uKCl7cmV0dXJuIFZhKHhnLHlnLGlnLGVnLHRnLEp2LGt2LHd2
LHQudXRjRm9ybWF0KS5kb21haW4oW0RhdGUuVVRDKDJlMywwLDEpLERhdGUuVVRDKDJlMywwLDIp
XSl9LHQuc2NoZW1lQ2F0ZWdvcnkxMD1VZyx0LnNjaGVtZUNhdGVnb3J5MjBiPU9nLHQuc2NoZW1l
Q2F0ZWdvcnkyMGM9RmcsdC5zY2hlbWVDYXRlZ29yeTIwPUlnLHQuaW50ZXJwb2xhdGVDdWJlaGVs
aXhEZWZhdWx0PVlnLHQuaW50ZXJwb2xhdGVSYWluYm93PWZ1bmN0aW9uKHQpeyh0PDB8fHQ+MSkm
Jih0LT1NYXRoLmZsb29yKHQpKTt2YXIgbj1NYXRoLmFicyh0LS41KTtyZXR1cm4gamcuaD0zNjAq
dC0xMDAsamcucz0xLjUtMS41Km4samcubD0uOC0uOSpuLGpnKyIifSx0LmludGVycG9sYXRlV2Fy
bT1CZyx0LmludGVycG9sYXRlQ29vbD1IZyx0LmludGVycG9sYXRlVmlyaWRpcz1YZyx0LmludGVy
cG9sYXRlTWFnbWE9VmcsdC5pbnRlcnBvbGF0ZUluZmVybm89JGcsdC5pbnRlcnBvbGF0ZVBsYXNt
YT1XZyx0LnNjYWxlU2VxdWVudGlhbD1aYSx0LmNyZWF0ZT1mdW5jdGlvbih0KXtyZXR1cm4gY3Qo
QSh0KS5jYWxsKGRvY3VtZW50LmRvY3VtZW50RWxlbWVudCkpfSx0LmNyZWF0b3I9QSx0LmxvY2Fs
PXN0LHQubWF0Y2hlcj1vZix0Lm1vdXNlPXB0LHQubmFtZXNwYWNlPUUsdC5uYW1lc3BhY2VzPXRm
LHQuY2xpZW50UG9pbnQ9aHQsdC5zZWxlY3Q9Y3QsdC5zZWxlY3RBbGw9ZnVuY3Rpb24odCl7cmV0
dXJuInN0cmluZyI9PXR5cGVvZiB0P25ldyB1dChbZG9jdW1lbnQucXVlcnlTZWxlY3RvckFsbCh0
KV0sW2RvY3VtZW50LmRvY3VtZW50RWxlbWVudF0pOm5ldyB1dChbbnVsbD09dD9bXTp0XSxjZil9
LHQuc2VsZWN0aW9uPWF0LHQuc2VsZWN0b3I9eix0LnNlbGVjdG9yQWxsPVIsdC5zdHlsZT1JLHQu
dG91Y2g9ZHQsdC50b3VjaGVzPWZ1bmN0aW9uKHQsbil7bnVsbD09biYmKG49bHQoKS50b3VjaGVz
KTtmb3IodmFyIGU9MCxyPW4/bi5sZW5ndGg6MCxpPW5ldyBBcnJheShyKTtlPHI7KytlKWlbZV09
aHQodCxuW2VdKTtyZXR1cm4gaX0sdC53aW5kb3c9Rix0LmN1c3RvbUV2ZW50PWl0LHQuYXJjPWZ1
bmN0aW9uKCl7ZnVuY3Rpb24gdCgpe3ZhciB0LHMsZj0rbi5hcHBseSh0aGlzLGFyZ3VtZW50cyks
bD0rZS5hcHBseSh0aGlzLGFyZ3VtZW50cyksaD1vLmFwcGx5KHRoaXMsYXJndW1lbnRzKS1pXyxw
PXUuYXBwbHkodGhpcyxhcmd1bWVudHMpLWlfLGQ9WmcocC1oKSx2PXA+aDtpZihjfHwoYz10PWVl
KCkpLGw8ZiYmKHM9bCxsPWYsZj1zKSxsPmVfKWlmKGQ+b18tZV8pYy5tb3ZlVG8obCpRZyhoKSxs
KnRfKGgpKSxjLmFyYygwLDAsbCxoLHAsIXYpLGY+ZV8mJihjLm1vdmVUbyhmKlFnKHApLGYqdF8o
cCkpLGMuYXJjKDAsMCxmLHAsaCx2KSk7ZWxzZXt2YXIgZyxfLHk9aCxtPXAseD1oLGI9cCx3PWQs
TT1kLFQ9YS5hcHBseSh0aGlzLGFyZ3VtZW50cykvMixOPVQ+ZV8mJihpPytpLmFwcGx5KHRoaXMs
YXJndW1lbnRzKTpuXyhmKmYrbCpsKSksaz1LZyhaZyhsLWYpLzIsK3IuYXBwbHkodGhpcyxhcmd1
bWVudHMpKSxTPWssRT1rO2lmKE4+ZV8pe3ZhciBBPVFhKE4vZip0XyhUKSksQz1RYShOL2wqdF8o
VCkpOyh3LT0yKkEpPmVfPyhBKj12PzE6LTEseCs9QSxiLT1BKToodz0wLHg9Yj0oaCtwKS8yKSwo
TS09MipDKT5lXz8oQyo9dj8xOi0xLHkrPUMsbS09Qyk6KE09MCx5PW09KGgrcCkvMil9dmFyIHo9
bCpRZyh5KSxQPWwqdF8oeSksUj1mKlFnKGIpLEw9Zip0XyhiKTtpZihrPmVfKXt2YXIgcT1sKlFn
KG0pLEQ9bCp0XyhtKSxVPWYqUWcoeCksTz1mKnRfKHgpO2lmKGQ8cl8pe3ZhciBGPXc+ZV8/ZnVu
Y3Rpb24odCxuLGUscixpLG8sdSxhKXt2YXIgYz1lLXQscz1yLW4sZj11LWksbD1hLW8saD0oZioo
bi1vKS1sKih0LWkpKS8obCpjLWYqcyk7cmV0dXJuW3QraCpjLG4raCpzXX0oeixQLFUsTyxxLEQs
UixMKTpbUixMXSxJPXotRlswXSxZPVAtRlsxXSxCPXEtRlswXSxIPUQtRlsxXSxqPTEvdF8oZnVu
Y3Rpb24odCl7cmV0dXJuIHQ+MT8wOnQ8LTE/cl86TWF0aC5hY29zKHQpfSgoSSpCK1kqSCkvKG5f
KEkqSStZKlkpKm5fKEIqQitIKkgpKSkvMiksWD1uXyhGWzBdKkZbMF0rRlsxXSpGWzFdKTtTPUtn
KGssKGYtWCkvKGotMSkpLEU9S2coaywobC1YKS8oaisxKSl9fU0+ZV8/RT5lXz8oZz1yYyhVLE8s
eixQLGwsRSx2KSxfPXJjKHEsRCxSLEwsbCxFLHYpLGMubW92ZVRvKGcuY3grZy54MDEsZy5jeStn
LnkwMSksRTxrP2MuYXJjKGcuY3gsZy5jeSxFLEdnKGcueTAxLGcueDAxKSxHZyhfLnkwMSxfLngw
MSksIXYpOihjLmFyYyhnLmN4LGcuY3ksRSxHZyhnLnkwMSxnLngwMSksR2coZy55MTEsZy54MTEp
LCF2KSxjLmFyYygwLDAsbCxHZyhnLmN5K2cueTExLGcuY3grZy54MTEpLEdnKF8uY3krXy55MTEs
Xy5jeCtfLngxMSksIXYpLGMuYXJjKF8uY3gsXy5jeSxFLEdnKF8ueTExLF8ueDExKSxHZyhfLnkw
MSxfLngwMSksIXYpKSk6KGMubW92ZVRvKHosUCksYy5hcmMoMCwwLGwseSxtLCF2KSk6Yy5tb3Zl
VG8oeixQKSxmPmVfJiZ3PmVfP1M+ZV8/KGc9cmMoUixMLHEsRCxmLC1TLHYpLF89cmMoeixQLFUs
TyxmLC1TLHYpLGMubGluZVRvKGcuY3grZy54MDEsZy5jeStnLnkwMSksUzxrP2MuYXJjKGcuY3gs
Zy5jeSxTLEdnKGcueTAxLGcueDAxKSxHZyhfLnkwMSxfLngwMSksIXYpOihjLmFyYyhnLmN4LGcu
Y3ksUyxHZyhnLnkwMSxnLngwMSksR2coZy55MTEsZy54MTEpLCF2KSxjLmFyYygwLDAsZixHZyhn
LmN5K2cueTExLGcuY3grZy54MTEpLEdnKF8uY3krXy55MTEsXy5jeCtfLngxMSksdiksYy5hcmMo
Xy5jeCxfLmN5LFMsR2coXy55MTEsXy54MTEpLEdnKF8ueTAxLF8ueDAxKSwhdikpKTpjLmFyYygw
LDAsZixiLHgsdik6Yy5saW5lVG8oUixMKX1lbHNlIGMubW92ZVRvKDAsMCk7aWYoYy5jbG9zZVBh
dGgoKSx0KXJldHVybiBjPW51bGwsdCsiInx8bnVsbH12YXIgbj1KYSxlPUthLHI9R2EoMCksaT1u
dWxsLG89dGMsdT1uYyxhPWVjLGM9bnVsbDtyZXR1cm4gdC5jZW50cm9pZD1mdW5jdGlvbigpe3Zh
ciB0PSgrbi5hcHBseSh0aGlzLGFyZ3VtZW50cykrICtlLmFwcGx5KHRoaXMsYXJndW1lbnRzKSkv
MixyPSgrby5hcHBseSh0aGlzLGFyZ3VtZW50cykrICt1LmFwcGx5KHRoaXMsYXJndW1lbnRzKSkv
Mi1yXy8yO3JldHVybltRZyhyKSp0LHRfKHIpKnRdfSx0LmlubmVyUmFkaXVzPWZ1bmN0aW9uKGUp
e3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhuPSJmdW5jdGlvbiI9PXR5cGVvZiBlP2U6R2EoK2Up
LHQpOm59LHQub3V0ZXJSYWRpdXM9ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/
KGU9ImZ1bmN0aW9uIj09dHlwZW9mIG4/bjpHYSgrbiksdCk6ZX0sdC5jb3JuZXJSYWRpdXM9ZnVu
Y3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KHI9ImZ1bmN0aW9uIj09dHlwZW9mIG4/
bjpHYSgrbiksdCk6cn0sdC5wYWRSYWRpdXM9ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5s
ZW5ndGg/KGk9bnVsbD09bj9udWxsOiJmdW5jdGlvbiI9PXR5cGVvZiBuP246R2EoK24pLHQpOml9
LHQuc3RhcnRBbmdsZT1mdW5jdGlvbihuKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8obz0iZnVu
Y3Rpb24iPT10eXBlb2Ygbj9uOkdhKCtuKSx0KTpvfSx0LmVuZEFuZ2xlPWZ1bmN0aW9uKG4pe3Jl
dHVybiBhcmd1bWVudHMubGVuZ3RoPyh1PSJmdW5jdGlvbiI9PXR5cGVvZiBuP246R2EoK24pLHQp
OnV9LHQucGFkQW5nbGU9ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KGE9ImZ1
bmN0aW9uIj09dHlwZW9mIG4/bjpHYSgrbiksdCk6YX0sdC5jb250ZXh0PWZ1bmN0aW9uKG4pe3Jl
dHVybiBhcmd1bWVudHMubGVuZ3RoPyhjPW51bGw9PW4/bnVsbDpuLHQpOmN9LHR9LHQuYXJlYT1z
Yyx0LmxpbmU9Y2MsdC5waWU9ZnVuY3Rpb24oKXtmdW5jdGlvbiB0KHQpe3ZhciBhLGMscyxmLGws
aD10Lmxlbmd0aCxwPTAsZD1uZXcgQXJyYXkoaCksdj1uZXcgQXJyYXkoaCksZz0raS5hcHBseSh0
aGlzLGFyZ3VtZW50cyksXz1NYXRoLm1pbihvXyxNYXRoLm1heCgtb18sby5hcHBseSh0aGlzLGFy
Z3VtZW50cyktZykpLHk9TWF0aC5taW4oTWF0aC5hYnMoXykvaCx1LmFwcGx5KHRoaXMsYXJndW1l
bnRzKSksbT15KihfPDA/LTE6MSk7Zm9yKGE9MDthPGg7KythKShsPXZbZFthXT1hXT0rbih0W2Fd
LGEsdCkpPjAmJihwKz1sKTtmb3IobnVsbCE9ZT9kLnNvcnQoZnVuY3Rpb24odCxuKXtyZXR1cm4g
ZSh2W3RdLHZbbl0pfSk6bnVsbCE9ciYmZC5zb3J0KGZ1bmN0aW9uKG4sZSl7cmV0dXJuIHIodFtu
XSx0W2VdKX0pLGE9MCxzPXA/KF8taCptKS9wOjA7YTxoOysrYSxnPWYpYz1kW2FdLGY9ZysoKGw9
dltjXSk+MD9sKnM6MCkrbSx2W2NdPXtkYXRhOnRbY10saW5kZXg6YSx2YWx1ZTpsLHN0YXJ0QW5n
bGU6ZyxlbmRBbmdsZTpmLHBhZEFuZ2xlOnl9O3JldHVybiB2fXZhciBuPWxjLGU9ZmMscj1udWxs
LGk9R2EoMCksbz1HYShvXyksdT1HYSgwKTtyZXR1cm4gdC52YWx1ZT1mdW5jdGlvbihlKXtyZXR1
cm4gYXJndW1lbnRzLmxlbmd0aD8obj0iZnVuY3Rpb24iPT10eXBlb2YgZT9lOkdhKCtlKSx0KTpu
fSx0LnNvcnRWYWx1ZXM9ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KGU9bixy
PW51bGwsdCk6ZX0sdC5zb3J0PWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhy
PW4sZT1udWxsLHQpOnJ9LHQuc3RhcnRBbmdsZT1mdW5jdGlvbihuKXtyZXR1cm4gYXJndW1lbnRz
Lmxlbmd0aD8oaT0iZnVuY3Rpb24iPT10eXBlb2Ygbj9uOkdhKCtuKSx0KTppfSx0LmVuZEFuZ2xl
PWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhvPSJmdW5jdGlvbiI9PXR5cGVv
ZiBuP246R2EoK24pLHQpOm99LHQucGFkQW5nbGU9ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50
cy5sZW5ndGg/KHU9ImZ1bmN0aW9uIj09dHlwZW9mIG4/bjpHYSgrbiksdCk6dX0sdH0sdC5hcmVh
UmFkaWFsPWdjLHQucmFkaWFsQXJlYT1nYyx0LmxpbmVSYWRpYWw9dmMsdC5yYWRpYWxMaW5lPXZj
LHQucG9pbnRSYWRpYWw9X2MsdC5saW5rSG9yaXpvbnRhbD1mdW5jdGlvbigpe3JldHVybiB4Yyhi
Yyl9LHQubGlua1ZlcnRpY2FsPWZ1bmN0aW9uKCl7cmV0dXJuIHhjKHdjKX0sdC5saW5rUmFkaWFs
PWZ1bmN0aW9uKCl7dmFyIHQ9eGMoTWMpO3JldHVybiB0LmFuZ2xlPXQueCxkZWxldGUgdC54LHQu
cmFkaXVzPXQueSxkZWxldGUgdC55LHR9LHQuc3ltYm9sPWZ1bmN0aW9uKCl7ZnVuY3Rpb24gdCgp
e3ZhciB0O2lmKHJ8fChyPXQ9ZWUoKSksbi5hcHBseSh0aGlzLGFyZ3VtZW50cykuZHJhdyhyLCtl
LmFwcGx5KHRoaXMsYXJndW1lbnRzKSksdClyZXR1cm4gcj1udWxsLHQrIiJ8fG51bGx9dmFyIG49
R2EoY18pLGU9R2EoNjQpLHI9bnVsbDtyZXR1cm4gdC50eXBlPWZ1bmN0aW9uKGUpe3JldHVybiBh
cmd1bWVudHMubGVuZ3RoPyhuPSJmdW5jdGlvbiI9PXR5cGVvZiBlP2U6R2EoZSksdCk6bn0sdC5z
aXplPWZ1bmN0aW9uKG4pe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhlPSJmdW5jdGlvbiI9PXR5
cGVvZiBuP246R2EoK24pLHQpOmV9LHQuY29udGV4dD1mdW5jdGlvbihuKXtyZXR1cm4gYXJndW1l
bnRzLmxlbmd0aD8ocj1udWxsPT1uP251bGw6bix0KTpyfSx0fSx0LnN5bWJvbHM9VF8sdC5zeW1i
b2xDaXJjbGU9Y18sdC5zeW1ib2xDcm9zcz1zXyx0LnN5bWJvbERpYW1vbmQ9aF8sdC5zeW1ib2xT
cXVhcmU9X18sdC5zeW1ib2xTdGFyPWdfLHQuc3ltYm9sVHJpYW5nbGU9bV8sdC5zeW1ib2xXeWU9
TV8sdC5jdXJ2ZUJhc2lzQ2xvc2VkPWZ1bmN0aW9uKHQpe3JldHVybiBuZXcgU2ModCl9LHQuY3Vy
dmVCYXNpc09wZW49ZnVuY3Rpb24odCl7cmV0dXJuIG5ldyBFYyh0KX0sdC5jdXJ2ZUJhc2lzPWZ1
bmN0aW9uKHQpe3JldHVybiBuZXcga2ModCl9LHQuY3VydmVCdW5kbGU9Tl8sdC5jdXJ2ZUNhcmRp
bmFsQ2xvc2VkPVNfLHQuY3VydmVDYXJkaW5hbE9wZW49RV8sdC5jdXJ2ZUNhcmRpbmFsPWtfLHQu
Y3VydmVDYXRtdWxsUm9tQ2xvc2VkPUNfLHQuY3VydmVDYXRtdWxsUm9tT3Blbj16Xyx0LmN1cnZl
Q2F0bXVsbFJvbT1BXyx0LmN1cnZlTGluZWFyQ2xvc2VkPWZ1bmN0aW9uKHQpe3JldHVybiBuZXcg
T2ModCl9LHQuY3VydmVMaW5lYXI9b2MsdC5jdXJ2ZU1vbm90b25lWD1mdW5jdGlvbih0KXtyZXR1
cm4gbmV3IEhjKHQpfSx0LmN1cnZlTW9ub3RvbmVZPWZ1bmN0aW9uKHQpe3JldHVybiBuZXcgamMo
dCl9LHQuY3VydmVOYXR1cmFsPWZ1bmN0aW9uKHQpe3JldHVybiBuZXcgVmModCl9LHQuY3VydmVT
dGVwPWZ1bmN0aW9uKHQpe3JldHVybiBuZXcgV2ModCwuNSl9LHQuY3VydmVTdGVwQWZ0ZXI9ZnVu
Y3Rpb24odCl7cmV0dXJuIG5ldyBXYyh0LDEpfSx0LmN1cnZlU3RlcEJlZm9yZT1mdW5jdGlvbih0
KXtyZXR1cm4gbmV3IFdjKHQsMCl9LHQuc3RhY2s9ZnVuY3Rpb24oKXtmdW5jdGlvbiB0KHQpe3Zh
ciBvLHUsYT1uLmFwcGx5KHRoaXMsYXJndW1lbnRzKSxjPXQubGVuZ3RoLHM9YS5sZW5ndGgsZj1u
ZXcgQXJyYXkocyk7Zm9yKG89MDtvPHM7KytvKXtmb3IodmFyIGwsaD1hW29dLHA9ZltvXT1uZXcg
QXJyYXkoYyksZD0wO2Q8YzsrK2QpcFtkXT1sPVswLCtpKHRbZF0saCxkLHQpXSxsLmRhdGE9dFtk
XTtwLmtleT1ofWZvcihvPTAsdT1lKGYpO288czsrK28pZlt1W29dXS5pbmRleD1vO3JldHVybiBy
KGYsdSksZn12YXIgbj1HYShbXSksZT1HYyxyPVpjLGk9UWM7cmV0dXJuIHQua2V5cz1mdW5jdGlv
bihlKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8obj0iZnVuY3Rpb24iPT10eXBlb2YgZT9lOkdh
KGFfLmNhbGwoZSkpLHQpOm59LHQudmFsdWU9ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5s
ZW5ndGg/KGk9ImZ1bmN0aW9uIj09dHlwZW9mIG4/bjpHYSgrbiksdCk6aX0sdC5vcmRlcj1mdW5j
dGlvbihuKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oZT1udWxsPT1uP0djOiJmdW5jdGlvbiI9
PXR5cGVvZiBuP246R2EoYV8uY2FsbChuKSksdCk6ZX0sdC5vZmZzZXQ9ZnVuY3Rpb24obil7cmV0
dXJuIGFyZ3VtZW50cy5sZW5ndGg/KHI9bnVsbD09bj9aYzpuLHQpOnJ9LHR9LHQuc3RhY2tPZmZz
ZXRFeHBhbmQ9ZnVuY3Rpb24odCxuKXtpZigocj10Lmxlbmd0aCk+MCl7Zm9yKHZhciBlLHIsaSxv
PTAsdT10WzBdLmxlbmd0aDtvPHU7KytvKXtmb3IoaT1lPTA7ZTxyOysrZSlpKz10W2VdW29dWzFd
fHwwO2lmKGkpZm9yKGU9MDtlPHI7KytlKXRbZV1bb11bMV0vPWl9WmModCxuKX19LHQuc3RhY2tP
ZmZzZXREaXZlcmdpbmc9ZnVuY3Rpb24odCxuKXtpZigoYT10Lmxlbmd0aCk+MSlmb3IodmFyIGUs
cixpLG8sdSxhLGM9MCxzPXRbblswXV0ubGVuZ3RoO2M8czsrK2MpZm9yKG89dT0wLGU9MDtlPGE7
KytlKShpPShyPXRbbltlXV1bY10pWzFdLXJbMF0pPj0wPyhyWzBdPW8sclsxXT1vKz1pKTppPDA/
KHJbMV09dSxyWzBdPXUrPWkpOnJbMF09b30sdC5zdGFja09mZnNldE5vbmU9WmMsdC5zdGFja09m
ZnNldFNpbGhvdWV0dGU9ZnVuY3Rpb24odCxuKXtpZigoZT10Lmxlbmd0aCk+MCl7Zm9yKHZhciBl
LHI9MCxpPXRbblswXV0sbz1pLmxlbmd0aDtyPG87KytyKXtmb3IodmFyIHU9MCxhPTA7dTxlOysr
dSlhKz10W3VdW3JdWzFdfHwwO2lbcl1bMV0rPWlbcl1bMF09LWEvMn1aYyh0LG4pfX0sdC5zdGFj
a09mZnNldFdpZ2dsZT1mdW5jdGlvbih0LG4pe2lmKChpPXQubGVuZ3RoKT4wJiYocj0oZT10W25b
MF1dKS5sZW5ndGgpPjApe2Zvcih2YXIgZSxyLGksbz0wLHU9MTt1PHI7Kyt1KXtmb3IodmFyIGE9
MCxjPTAscz0wO2E8aTsrK2Epe2Zvcih2YXIgZj10W25bYV1dLGw9Zlt1XVsxXXx8MCxoPShsLShm
W3UtMV1bMV18fDApKS8yLHA9MDtwPGE7KytwKXt2YXIgZD10W25bcF1dO2grPShkW3VdWzFdfHww
KS0oZFt1LTFdWzFdfHwwKX1jKz1sLHMrPWgqbH1lW3UtMV1bMV0rPWVbdS0xXVswXT1vLGMmJihv
LT1zL2MpfWVbdS0xXVsxXSs9ZVt1LTFdWzBdPW8sWmModCxuKX19LHQuc3RhY2tPcmRlckFzY2Vu
ZGluZz1KYyx0LnN0YWNrT3JkZXJEZXNjZW5kaW5nPWZ1bmN0aW9uKHQpe3JldHVybiBKYyh0KS5y
ZXZlcnNlKCl9LHQuc3RhY2tPcmRlckluc2lkZU91dD1mdW5jdGlvbih0KXt2YXIgbixlLHI9dC5s
ZW5ndGgsaT10Lm1hcChLYyksbz1HYyh0KS5zb3J0KGZ1bmN0aW9uKHQsbil7cmV0dXJuIGlbbl0t
aVt0XX0pLHU9MCxhPTAsYz1bXSxzPVtdO2ZvcihuPTA7bjxyOysrbillPW9bbl0sdTxhPyh1Kz1p
W2VdLGMucHVzaChlKSk6KGErPWlbZV0scy5wdXNoKGUpKTtyZXR1cm4gcy5yZXZlcnNlKCkuY29u
Y2F0KGMpfSx0LnN0YWNrT3JkZXJOb25lPUdjLHQuc3RhY2tPcmRlclJldmVyc2U9ZnVuY3Rpb24o
dCl7cmV0dXJuIEdjKHQpLnJldmVyc2UoKX0sdC50aW1lSW50ZXJ2YWw9Q3UsdC50aW1lTWlsbGlz
ZWNvbmQ9d3YsdC50aW1lTWlsbGlzZWNvbmRzPU12LHQudXRjTWlsbGlzZWNvbmQ9d3YsdC51dGNN
aWxsaXNlY29uZHM9TXYsdC50aW1lU2Vjb25kPWt2LHQudGltZVNlY29uZHM9U3YsdC51dGNTZWNv
bmQ9a3YsdC51dGNTZWNvbmRzPVN2LHQudGltZU1pbnV0ZT1Fdix0LnRpbWVNaW51dGVzPUF2LHQu
dGltZUhvdXI9Q3YsdC50aW1lSG91cnM9enYsdC50aW1lRGF5PVB2LHQudGltZURheXM9UnYsdC50
aW1lV2Vlaz1Mdix0LnRpbWVXZWVrcz1Zdix0LnRpbWVTdW5kYXk9THYsdC50aW1lU3VuZGF5cz1Z
dix0LnRpbWVNb25kYXk9cXYsdC50aW1lTW9uZGF5cz1Cdix0LnRpbWVUdWVzZGF5PUR2LHQudGlt
ZVR1ZXNkYXlzPUh2LHQudGltZVdlZG5lc2RheT1Vdix0LnRpbWVXZWRuZXNkYXlzPWp2LHQudGlt
ZVRodXJzZGF5PU92LHQudGltZVRodXJzZGF5cz1Ydix0LnRpbWVGcmlkYXk9RnYsdC50aW1lRnJp
ZGF5cz1Wdix0LnRpbWVTYXR1cmRheT1Jdix0LnRpbWVTYXR1cmRheXM9JHYsdC50aW1lTW9udGg9
V3YsdC50aW1lTW9udGhzPVp2LHQudGltZVllYXI9R3YsdC50aW1lWWVhcnM9UXYsdC51dGNNaW51
dGU9SnYsdC51dGNNaW51dGVzPUt2LHQudXRjSG91cj10Zyx0LnV0Y0hvdXJzPW5nLHQudXRjRGF5
PWVnLHQudXRjRGF5cz1yZyx0LnV0Y1dlZWs9aWcsdC51dGNXZWVrcz1sZyx0LnV0Y1N1bmRheT1p
Zyx0LnV0Y1N1bmRheXM9bGcsdC51dGNNb25kYXk9b2csdC51dGNNb25kYXlzPWhnLHQudXRjVHVl
c2RheT11Zyx0LnV0Y1R1ZXNkYXlzPXBnLHQudXRjV2VkbmVzZGF5PWFnLHQudXRjV2VkbmVzZGF5
cz1kZyx0LnV0Y1RodXJzZGF5PWNnLHQudXRjVGh1cnNkYXlzPXZnLHQudXRjRnJpZGF5PXNnLHQu
dXRjRnJpZGF5cz1nZyx0LnV0Y1NhdHVyZGF5PWZnLHQudXRjU2F0dXJkYXlzPV9nLHQudXRjTW9u
dGg9eWcsdC51dGNNb250aHM9bWcsdC51dGNZZWFyPXhnLHQudXRjWWVhcnM9d2csdC50aW1lRm9y
bWF0RGVmYXVsdExvY2FsZT1IYSx0LnRpbWVGb3JtYXRMb2NhbGU9RHUsdC5pc29Gb3JtYXQ9RWcs
dC5pc29QYXJzZT1BZyx0Lm5vdz1tbix0LnRpbWVyPXduLHQudGltZXJGbHVzaD1Nbix0LnRpbWVv
dXQ9U24sdC5pbnRlcnZhbD1mdW5jdGlvbih0LG4sZSl7dmFyIHI9bmV3IGJuLGk9bjtyZXR1cm4g
bnVsbD09bj8oci5yZXN0YXJ0KHQsbixlKSxyKToobj0rbixlPW51bGw9PWU/bW4oKTorZSxyLnJl
c3RhcnQoZnVuY3Rpb24gbyh1KXt1Kz1pLHIucmVzdGFydChvLGkrPW4sZSksdCh1KX0sbixlKSxy
KX0sdC50cmFuc2l0aW9uPURuLHQuYWN0aXZlPWZ1bmN0aW9uKHQsbil7dmFyIGUscixpPXQuX190
cmFuc2l0aW9uO2lmKGkpe249bnVsbD09bj9udWxsOm4rIiI7Zm9yKHIgaW4gaSlpZigoZT1pW3Jd
KS5zdGF0ZT54bCYmZS5uYW1lPT09bilyZXR1cm4gbmV3IHFuKFtbdF1dLEpsLG4sK3IpfXJldHVy
biBudWxsfSx0LmludGVycnVwdD1Qbix0LnZvcm9ub2k9ZnVuY3Rpb24oKXtmdW5jdGlvbiB0KHQp
e3JldHVybiBuZXcgTnModC5tYXAoZnVuY3Rpb24ocixpKXt2YXIgbz1bTWF0aC5yb3VuZChuKHIs
aSx0KS9GXykqRl8sTWF0aC5yb3VuZChlKHIsaSx0KS9GXykqRl9dO3JldHVybiBvLmluZGV4PWks
by5kYXRhPXIsb30pLHIpfXZhciBuPW5zLGU9ZXMscj1udWxsO3JldHVybiB0LnBvbHlnb25zPWZ1
bmN0aW9uKG4pe3JldHVybiB0KG4pLnBvbHlnb25zKCl9LHQubGlua3M9ZnVuY3Rpb24obil7cmV0
dXJuIHQobikubGlua3MoKX0sdC50cmlhbmdsZXM9ZnVuY3Rpb24obil7cmV0dXJuIHQobikudHJp
YW5nbGVzKCl9LHQueD1mdW5jdGlvbihlKXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8obj0iZnVu
Y3Rpb24iPT10eXBlb2YgZT9lOnRzKCtlKSx0KTpufSx0Lnk9ZnVuY3Rpb24obil7cmV0dXJuIGFy
Z3VtZW50cy5sZW5ndGg/KGU9ImZ1bmN0aW9uIj09dHlwZW9mIG4/bjp0cygrbiksdCk6ZX0sdC5l
eHRlbnQ9ZnVuY3Rpb24obil7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KHI9bnVsbD09bj9udWxs
OltbK25bMF1bMF0sK25bMF1bMV1dLFsrblsxXVswXSwrblsxXVsxXV1dLHQpOnImJltbclswXVsw
XSxyWzBdWzFdXSxbclsxXVswXSxyWzFdWzFdXV19LHQuc2l6ZT1mdW5jdGlvbihuKXtyZXR1cm4g
YXJndW1lbnRzLmxlbmd0aD8ocj1udWxsPT1uP251bGw6W1swLDBdLFsrblswXSwrblsxXV1dLHQp
OnImJltyWzFdWzBdLXJbMF1bMF0sclsxXVsxXS1yWzBdWzFdXX0sdH0sdC56b29tPWZ1bmN0aW9u
KCl7ZnVuY3Rpb24gbih0KXt0LnByb3BlcnR5KCJfX3pvb20iLFJzKS5vbigid2hlZWwuem9vbSIs
Yykub24oIm1vdXNlZG93bi56b29tIixzKS5vbigiZGJsY2xpY2suem9vbSIsZikuZmlsdGVyKHgp
Lm9uKCJ0b3VjaHN0YXJ0Lnpvb20iLGwpLm9uKCJ0b3VjaG1vdmUuem9vbSIsaCkub24oInRvdWNo
ZW5kLnpvb20gdG91Y2hjYW5jZWwuem9vbSIscCkuc3R5bGUoInRvdWNoLWFjdGlvbiIsIm5vbmUi
KS5zdHlsZSgiLXdlYmtpdC10YXAtaGlnaGxpZ2h0LWNvbG9yIiwicmdiYSgwLDAsMCwwKSIpfWZ1
bmN0aW9uIGUodCxuKXtyZXR1cm4obj1NYXRoLm1heChiWzBdLE1hdGgubWluKGJbMV0sbikpKT09
PXQuaz90Om5ldyBTcyhuLHQueCx0LnkpfWZ1bmN0aW9uIHIodCxuLGUpe3ZhciByPW5bMF0tZVsw
XSp0LmssaT1uWzFdLWVbMV0qdC5rO3JldHVybiByPT09dC54JiZpPT09dC55P3Q6bmV3IFNzKHQu
ayxyLGkpfWZ1bmN0aW9uIGkodCl7cmV0dXJuWygrdFswXVswXSsgK3RbMV1bMF0pLzIsKCt0WzBd
WzFdKyArdFsxXVsxXSkvMl19ZnVuY3Rpb24gbyh0LG4sZSl7dC5vbigic3RhcnQuem9vbSIsZnVu
Y3Rpb24oKXt1KHRoaXMsYXJndW1lbnRzKS5zdGFydCgpfSkub24oImludGVycnVwdC56b29tIGVu
ZC56b29tIixmdW5jdGlvbigpe3UodGhpcyxhcmd1bWVudHMpLmVuZCgpfSkudHdlZW4oInpvb20i
LGZ1bmN0aW9uKCl7dmFyIHQ9YXJndW1lbnRzLHI9dSh0aGlzLHQpLG89Xy5hcHBseSh0aGlzLHQp
LGE9ZXx8aShvKSxjPU1hdGgubWF4KG9bMV1bMF0tb1swXVswXSxvWzFdWzFdLW9bMF1bMV0pLHM9
dGhpcy5fX3pvb20sZj0iZnVuY3Rpb24iPT10eXBlb2Ygbj9uLmFwcGx5KHRoaXMsdCk6bixsPVQo
cy5pbnZlcnQoYSkuY29uY2F0KGMvcy5rKSxmLmludmVydChhKS5jb25jYXQoYy9mLmspKTtyZXR1
cm4gZnVuY3Rpb24odCl7aWYoMT09PXQpdD1mO2Vsc2V7dmFyIG49bCh0KSxlPWMvblsyXTt0PW5l
dyBTcyhlLGFbMF0tblswXSplLGFbMV0tblsxXSplKX1yLnpvb20obnVsbCx0KX19KX1mdW5jdGlv
biB1KHQsbil7Zm9yKHZhciBlLHI9MCxpPWsubGVuZ3RoO3I8aTsrK3IpaWYoKGU9a1tyXSkudGhh
dD09PXQpcmV0dXJuIGU7cmV0dXJuIG5ldyBhKHQsbil9ZnVuY3Rpb24gYSh0LG4pe3RoaXMudGhh
dD10LHRoaXMuYXJncz1uLHRoaXMuaW5kZXg9LTEsdGhpcy5hY3RpdmU9MCx0aGlzLmV4dGVudD1f
LmFwcGx5KHQsbil9ZnVuY3Rpb24gYygpe2lmKGcuYXBwbHkodGhpcyxhcmd1bWVudHMpKXt2YXIg
dD11KHRoaXMsYXJndW1lbnRzKSxuPXRoaXMuX196b29tLGk9TWF0aC5tYXgoYlswXSxNYXRoLm1p
bihiWzFdLG4uaypNYXRoLnBvdygyLG0uYXBwbHkodGhpcyxhcmd1bWVudHMpKSkpLG89cHQodGhp
cyk7aWYodC53aGVlbCl0Lm1vdXNlWzBdWzBdPT09b1swXSYmdC5tb3VzZVswXVsxXT09PW9bMV18
fCh0Lm1vdXNlWzFdPW4uaW52ZXJ0KHQubW91c2VbMF09bykpLGNsZWFyVGltZW91dCh0LndoZWVs
KTtlbHNle2lmKG4uaz09PWkpcmV0dXJuO3QubW91c2U9W28sbi5pbnZlcnQobyldLFBuKHRoaXMp
LHQuc3RhcnQoKX1DcygpLHQud2hlZWw9c2V0VGltZW91dChmdW5jdGlvbigpe3Qud2hlZWw9bnVs
bCx0LmVuZCgpfSxBKSx0Lnpvb20oIm1vdXNlIix5KHIoZShuLGkpLHQubW91c2VbMF0sdC5tb3Vz
ZVsxXSksdC5leHRlbnQsdykpfX1mdW5jdGlvbiBzKCl7aWYoIXYmJmcuYXBwbHkodGhpcyxhcmd1
bWVudHMpKXt2YXIgbj11KHRoaXMsYXJndW1lbnRzKSxlPWN0KHQuZXZlbnQudmlldykub24oIm1v
dXNlbW92ZS56b29tIixmdW5jdGlvbigpe2lmKENzKCksIW4ubW92ZWQpe3ZhciBlPXQuZXZlbnQu
Y2xpZW50WC1vLGk9dC5ldmVudC5jbGllbnRZLWE7bi5tb3ZlZD1lKmUraSppPkN9bi56b29tKCJt
b3VzZSIseShyKG4udGhhdC5fX3pvb20sbi5tb3VzZVswXT1wdChuLnRoYXQpLG4ubW91c2VbMV0p
LG4uZXh0ZW50LHcpKX0sITApLm9uKCJtb3VzZXVwLnpvb20iLGZ1bmN0aW9uKCl7ZS5vbigibW91
c2Vtb3ZlLnpvb20gbW91c2V1cC56b29tIixudWxsKSx5dCh0LmV2ZW50LnZpZXcsbi5tb3ZlZCks
Q3MoKSxuLmVuZCgpfSwhMCksaT1wdCh0aGlzKSxvPXQuZXZlbnQuY2xpZW50WCxhPXQuZXZlbnQu
Y2xpZW50WTtfdCh0LmV2ZW50LnZpZXcpLEFzKCksbi5tb3VzZT1baSx0aGlzLl9fem9vbS5pbnZl
cnQoaSldLFBuKHRoaXMpLG4uc3RhcnQoKX19ZnVuY3Rpb24gZigpe2lmKGcuYXBwbHkodGhpcyxh
cmd1bWVudHMpKXt2YXIgaT10aGlzLl9fem9vbSx1PXB0KHRoaXMpLGE9aS5pbnZlcnQodSksYz1p
LmsqKHQuZXZlbnQuc2hpZnRLZXk/LjU6Mikscz15KHIoZShpLGMpLHUsYSksXy5hcHBseSh0aGlz
LGFyZ3VtZW50cyksdyk7Q3MoKSxNPjA/Y3QodGhpcykudHJhbnNpdGlvbigpLmR1cmF0aW9uKE0p
LmNhbGwobyxzLHUpOmN0KHRoaXMpLmNhbGwobi50cmFuc2Zvcm0scyl9fWZ1bmN0aW9uIGwoKXtp
ZihnLmFwcGx5KHRoaXMsYXJndW1lbnRzKSl7dmFyIG4sZSxyLGksbz11KHRoaXMsYXJndW1lbnRz
KSxhPXQuZXZlbnQuY2hhbmdlZFRvdWNoZXMsYz1hLmxlbmd0aDtmb3IoQXMoKSxlPTA7ZTxjOysr
ZSlpPVtpPWR0KHRoaXMsYSwocj1hW2VdKS5pZGVudGlmaWVyKSx0aGlzLl9fem9vbS5pbnZlcnQo
aSksci5pZGVudGlmaWVyXSxvLnRvdWNoMD9vLnRvdWNoMXx8KG8udG91Y2gxPWkpOihvLnRvdWNo
MD1pLG49ITApO2lmKGQmJihkPWNsZWFyVGltZW91dChkKSwhby50b3VjaDEpKXJldHVybiBvLmVu
ZCgpLHZvaWQoKGk9Y3QodGhpcykub24oImRibGNsaWNrLnpvb20iKSkmJmkuYXBwbHkodGhpcyxh
cmd1bWVudHMpKTtuJiYoZD1zZXRUaW1lb3V0KGZ1bmN0aW9uKCl7ZD1udWxsfSxFKSxQbih0aGlz
KSxvLnN0YXJ0KCkpfX1mdW5jdGlvbiBoKCl7dmFyIG4saSxvLGEsYz11KHRoaXMsYXJndW1lbnRz
KSxzPXQuZXZlbnQuY2hhbmdlZFRvdWNoZXMsZj1zLmxlbmd0aDtmb3IoQ3MoKSxkJiYoZD1jbGVh
clRpbWVvdXQoZCkpLG49MDtuPGY7KytuKW89ZHQodGhpcyxzLChpPXNbbl0pLmlkZW50aWZpZXIp
LGMudG91Y2gwJiZjLnRvdWNoMFsyXT09PWkuaWRlbnRpZmllcj9jLnRvdWNoMFswXT1vOmMudG91
Y2gxJiZjLnRvdWNoMVsyXT09PWkuaWRlbnRpZmllciYmKGMudG91Y2gxWzBdPW8pO2lmKGk9Yy50
aGF0Ll9fem9vbSxjLnRvdWNoMSl7dmFyIGw9Yy50b3VjaDBbMF0saD1jLnRvdWNoMFsxXSxwPWMu
dG91Y2gxWzBdLHY9Yy50b3VjaDFbMV0sZz0oZz1wWzBdLWxbMF0pKmcrKGc9cFsxXS1sWzFdKSpn
LF89KF89dlswXS1oWzBdKSpfKyhfPXZbMV0taFsxXSkqXztpPWUoaSxNYXRoLnNxcnQoZy9fKSks
bz1bKGxbMF0rcFswXSkvMiwobFsxXStwWzFdKS8yXSxhPVsoaFswXSt2WzBdKS8yLChoWzFdK3Zb
MV0pLzJdfWVsc2V7aWYoIWMudG91Y2gwKXJldHVybjtvPWMudG91Y2gwWzBdLGE9Yy50b3VjaDBb
MV19Yy56b29tKCJ0b3VjaCIseShyKGksbyxhKSxjLmV4dGVudCx3KSl9ZnVuY3Rpb24gcCgpe3Zh
ciBuLGUscj11KHRoaXMsYXJndW1lbnRzKSxpPXQuZXZlbnQuY2hhbmdlZFRvdWNoZXMsbz1pLmxl
bmd0aDtmb3IoQXMoKSx2JiZjbGVhclRpbWVvdXQodiksdj1zZXRUaW1lb3V0KGZ1bmN0aW9uKCl7
dj1udWxsfSxFKSxuPTA7bjxvOysrbillPWlbbl0sci50b3VjaDAmJnIudG91Y2gwWzJdPT09ZS5p
ZGVudGlmaWVyP2RlbGV0ZSByLnRvdWNoMDpyLnRvdWNoMSYmci50b3VjaDFbMl09PT1lLmlkZW50
aWZpZXImJmRlbGV0ZSByLnRvdWNoMTtyLnRvdWNoMSYmIXIudG91Y2gwJiYoci50b3VjaDA9ci50
b3VjaDEsZGVsZXRlIHIudG91Y2gxKSxyLnRvdWNoMD9yLnRvdWNoMFsxXT10aGlzLl9fem9vbS5p
bnZlcnQoci50b3VjaDBbMF0pOnIuZW5kKCl9dmFyIGQsdixnPXpzLF89UHMseT1EcyxtPUxzLHg9
cXMsYj1bMCwxLzBdLHc9W1stMS8wLC0xLzBdLFsxLzAsMS8wXV0sTT0yNTAsVD12bixrPVtdLFM9
Tigic3RhcnQiLCJ6b29tIiwiZW5kIiksRT01MDAsQT0xNTAsQz0wO3JldHVybiBuLnRyYW5zZm9y
bT1mdW5jdGlvbih0LG4pe3ZhciBlPXQuc2VsZWN0aW9uP3Quc2VsZWN0aW9uKCk6dDtlLnByb3Bl
cnR5KCJfX3pvb20iLFJzKSx0IT09ZT9vKHQsbik6ZS5pbnRlcnJ1cHQoKS5lYWNoKGZ1bmN0aW9u
KCl7dSh0aGlzLGFyZ3VtZW50cykuc3RhcnQoKS56b29tKG51bGwsImZ1bmN0aW9uIj09dHlwZW9m
IG4/bi5hcHBseSh0aGlzLGFyZ3VtZW50cyk6bikuZW5kKCl9KX0sbi5zY2FsZUJ5PWZ1bmN0aW9u
KHQsZSl7bi5zY2FsZVRvKHQsZnVuY3Rpb24oKXtyZXR1cm4gdGhpcy5fX3pvb20uayooImZ1bmN0
aW9uIj09dHlwZW9mIGU/ZS5hcHBseSh0aGlzLGFyZ3VtZW50cyk6ZSl9KX0sbi5zY2FsZVRvPWZ1
bmN0aW9uKHQsbyl7bi50cmFuc2Zvcm0odCxmdW5jdGlvbigpe3ZhciB0PV8uYXBwbHkodGhpcyxh
cmd1bWVudHMpLG49dGhpcy5fX3pvb20sdT1pKHQpLGE9bi5pbnZlcnQodSksYz0iZnVuY3Rpb24i
PT10eXBlb2Ygbz9vLmFwcGx5KHRoaXMsYXJndW1lbnRzKTpvO3JldHVybiB5KHIoZShuLGMpLHUs
YSksdCx3KX0pfSxuLnRyYW5zbGF0ZUJ5PWZ1bmN0aW9uKHQsZSxyKXtuLnRyYW5zZm9ybSh0LGZ1
bmN0aW9uKCl7cmV0dXJuIHkodGhpcy5fX3pvb20udHJhbnNsYXRlKCJmdW5jdGlvbiI9PXR5cGVv
ZiBlP2UuYXBwbHkodGhpcyxhcmd1bWVudHMpOmUsImZ1bmN0aW9uIj09dHlwZW9mIHI/ci5hcHBs
eSh0aGlzLGFyZ3VtZW50cyk6ciksXy5hcHBseSh0aGlzLGFyZ3VtZW50cyksdyl9KX0sbi50cmFu
c2xhdGVUbz1mdW5jdGlvbih0LGUscil7bi50cmFuc2Zvcm0odCxmdW5jdGlvbigpe3ZhciB0PV8u
YXBwbHkodGhpcyxhcmd1bWVudHMpLG49dGhpcy5fX3pvb20sbz1pKHQpO3JldHVybiB5KFlfLnRy
YW5zbGF0ZShvWzBdLG9bMV0pLnNjYWxlKG4uaykudHJhbnNsYXRlKCJmdW5jdGlvbiI9PXR5cGVv
ZiBlPy1lLmFwcGx5KHRoaXMsYXJndW1lbnRzKTotZSwiZnVuY3Rpb24iPT10eXBlb2Ygcj8tci5h
cHBseSh0aGlzLGFyZ3VtZW50cyk6LXIpLHQsdyl9KX0sYS5wcm90b3R5cGU9e3N0YXJ0OmZ1bmN0
aW9uKCl7cmV0dXJuIDE9PSsrdGhpcy5hY3RpdmUmJih0aGlzLmluZGV4PWsucHVzaCh0aGlzKS0x
LHRoaXMuZW1pdCgic3RhcnQiKSksdGhpc30sem9vbTpmdW5jdGlvbih0LG4pe3JldHVybiB0aGlz
Lm1vdXNlJiYibW91c2UiIT09dCYmKHRoaXMubW91c2VbMV09bi5pbnZlcnQodGhpcy5tb3VzZVsw
XSkpLHRoaXMudG91Y2gwJiYidG91Y2giIT09dCYmKHRoaXMudG91Y2gwWzFdPW4uaW52ZXJ0KHRo
aXMudG91Y2gwWzBdKSksdGhpcy50b3VjaDEmJiJ0b3VjaCIhPT10JiYodGhpcy50b3VjaDFbMV09
bi5pbnZlcnQodGhpcy50b3VjaDFbMF0pKSx0aGlzLnRoYXQuX196b29tPW4sdGhpcy5lbWl0KCJ6
b29tIiksdGhpc30sZW5kOmZ1bmN0aW9uKCl7cmV0dXJuIDA9PS0tdGhpcy5hY3RpdmUmJihrLnNw
bGljZSh0aGlzLmluZGV4LDEpLHRoaXMuaW5kZXg9LTEsdGhpcy5lbWl0KCJlbmQiKSksdGhpc30s
ZW1pdDpmdW5jdGlvbih0KXtpdChuZXcgZnVuY3Rpb24odCxuLGUpe3RoaXMudGFyZ2V0PXQsdGhp
cy50eXBlPW4sdGhpcy50cmFuc2Zvcm09ZX0obix0LHRoaXMudGhhdC5fX3pvb20pLFMuYXBwbHks
UyxbdCx0aGlzLnRoYXQsdGhpcy5hcmdzXSl9fSxuLndoZWVsRGVsdGE9ZnVuY3Rpb24odCl7cmV0
dXJuIGFyZ3VtZW50cy5sZW5ndGg/KG09ImZ1bmN0aW9uIj09dHlwZW9mIHQ/dDprcygrdCksbik6
bX0sbi5maWx0ZXI9ZnVuY3Rpb24odCl7cmV0dXJuIGFyZ3VtZW50cy5sZW5ndGg/KGc9ImZ1bmN0
aW9uIj09dHlwZW9mIHQ/dDprcyghIXQpLG4pOmd9LG4udG91Y2hhYmxlPWZ1bmN0aW9uKHQpe3Jl
dHVybiBhcmd1bWVudHMubGVuZ3RoPyh4PSJmdW5jdGlvbiI9PXR5cGVvZiB0P3Q6a3MoISF0KSxu
KTp4fSxuLmV4dGVudD1mdW5jdGlvbih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oXz0iZnVu
Y3Rpb24iPT10eXBlb2YgdD90OmtzKFtbK3RbMF1bMF0sK3RbMF1bMV1dLFsrdFsxXVswXSwrdFsx
XVsxXV1dKSxuKTpffSxuLnNjYWxlRXh0ZW50PWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMu
bGVuZ3RoPyhiWzBdPSt0WzBdLGJbMV09K3RbMV0sbik6W2JbMF0sYlsxXV19LG4udHJhbnNsYXRl
RXh0ZW50PWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyh3WzBdWzBdPSt0WzBd
WzBdLHdbMV1bMF09K3RbMV1bMF0sd1swXVsxXT0rdFswXVsxXSx3WzFdWzFdPSt0WzFdWzFdLG4p
Oltbd1swXVswXSx3WzBdWzFdXSxbd1sxXVswXSx3WzFdWzFdXV19LG4uY29uc3RyYWluPWZ1bmN0
aW9uKHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyh5PXQsbik6eX0sbi5kdXJhdGlvbj1mdW5j
dGlvbih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oTT0rdCxuKTpNfSxuLmludGVycG9sYXRl
PWZ1bmN0aW9uKHQpe3JldHVybiBhcmd1bWVudHMubGVuZ3RoPyhUPXQsbik6VH0sbi5vbj1mdW5j
dGlvbigpe3ZhciB0PVMub24uYXBwbHkoUyxhcmd1bWVudHMpO3JldHVybiB0PT09Uz9uOnR9LG4u
Y2xpY2tEaXN0YW5jZT1mdW5jdGlvbih0KXtyZXR1cm4gYXJndW1lbnRzLmxlbmd0aD8oQz0odD0r
dCkqdCxuKTpNYXRoLnNxcnQoQyl9LG59LHQuem9vbVRyYW5zZm9ybT1Fcyx0Lnpvb21JZGVudGl0
eT1ZXyxPYmplY3QuZGVmaW5lUHJvcGVydHkodCwiX19lc01vZHVsZSIse3ZhbHVlOiEwfSl9KTsK"
             )))
  repository)

(defun c/produce-json (repository)
  "Produce json for REPOSITORY."
  (message "Produce json...")
  (shell-command
   (format
    "cd /tmp; python csv_as_enclosure_json.py --structure cloc-%s.csv --weights %s-revisions.csv > /tmp/%s/%s_hotspot_proto.json"
    (f-filename repository)
    (f-filename repository)
    (f-filename repository)
    (f-filename repository)))
  repository)

(defun c/generate-host-enclosure-diagram-html (repository)
  "Generate host html from REPOSITORY."
  (with-temp-file (format "/tmp/%s/%szoomable.html" (f-filename repository) (f-filename repository))
    (insert
     (concat
      "<!DOCTYPE html>
<meta charset=\"utf-8\">
<style>

.node {
  cursor: pointer;
}

.node:hover {
  stroke: #000;
  stroke-width: 1.5px;
}

.node--root {
  stroke: #777;
  stroke-width: 2px;
}

.node--leaf {
  fill: white;
  stroke: #777;
  stroke-width: 1px;
}

.label {
  font: 14px \"Helvetica Neue\", Helvetica, Arial, sans-serif;
  text-anchor: middle;
  fill: white;
  //text-shadow: 0 1px 0 #fff, 1px 0 0 #fff, -1px 0 0 #fff, 0 -1px 0 #fff;
}

.label,
.node--root,
.node--leaf {
  pointer-events: none;
}

</style>
<body>
<script src=\"d3/d3.min.js\"></script>
<script>

var margin = 10,
    outerDiameter = 960,
    innerDiameter = outerDiameter - margin - margin;

var x = d3.scale.linear()
    .range([0, innerDiameter]);

var y = d3.scale.linear()
    .range([0, innerDiameter]);

var color = d3.scale.linear()
    .domain([-1, 5])
    .range([\"hsl(185,60%,99%)\", \"hsl(187,40%,70%)\"])
    .interpolate(d3.interpolateHcl);

var pack = d3.layout.pack()
    .padding(2)
    .size([innerDiameter, innerDiameter])
    .value(function(d) { return d.size; })

var svg = d3.select(\"body\").append(\"svg\")
    .attr(\"width\", outerDiameter)
    .attr(\"height\", outerDiameter)
  .append(\"g\")
    .attr(\"transform\", \"translate(\" + margin + \",\" + margin + \")\");

d3.json(\""
      (f-filename repository)
      "_hotspot_proto.json"
      "\", function(error, root) {
  var focus = root,
      nodes = pack.nodes(root);

  svg.append(\"g\").selectAll(\"circle\")
      .data(nodes)
    .enter().append(\"circle\")
      .attr(\"class\", function(d) { return d.parent ? d.children ? \"node\" : \"node node--leaf\" : \"node node--root\"; })
      .attr(\"transform\", function(d) { return \"translate(\" + d.x + \",\" + d.y + \")\"; })
      .attr(\"r\", function(d) { return d.r; })
      .style(\"fill\", function(d) { return d.weight > 0.0 ? \"darkred\" :
      d.children ? color(d.depth) : \"black\"; })
      .style(\"fill-opacity\", function(d) { return d.weight; })
      .on(\"click\", function(d) { return zoom(focus == d ? root : d); });

  svg.append(\"g\").selectAll(\"text\")
      .data(nodes)
    .enter().append(\"text\")
      .attr(\"class\", \"label\")
      .attr(\"transform\", function(d) { return \"translate(\" + d.x + \",\" + d.y + \")\"; })
      .style(\"fill-opacity\", function(d) { return d.parent === root ? 1 : 0; })
      .style(\"display\", function(d) { return d.parent === root ? null : \"none\"; })
      .text(function(d) { return d.name; });

  d3.select(window)
      .on(\"click\", function() { zoom(root); });

  function zoom(d, i) {
    var focus0 = focus;
    focus = d;

    var k = innerDiameter / d.r / 2;
    x.domain([d.x - d.r, d.x + d.r]);
    y.domain([d.y - d.r, d.y + d.r]);
    d3.event.stopPropagation();

    var transition = d3.selectAll(\"text,circle\").transition()
        .duration(d3.event.altKey ? 7500 : 750)
        .attr(\"transform\", function(d) { return \"translate(\" + x(d.x) + \",\" + y(d.y) + \")\"; });

    transition.filter(\"circle\")
        .attr(\"r\", function(d) { return k * d.r; });

    transition.filter(\"text\")
      .filter(function(d) { return d.parent === focus || d.parent === focus0; })
        .style(\"fill-opacity\", function(d) { return d.parent === focus ? 1 : 0; })
        .each(\"start\", function(d) { if (d.parent === focus) this.style.display = \"inline\"; })
        .each(\"end\", function(d) { if (d.parent !== focus) this.style.display = \"none\"; });
  }}
);

d3.select(self.frameElement).style(\"height\", outerDiameter + \"px\");

</script>


")))
  repository)

(defun c/navigate-to-localhost (repository &optional port)
  "Navigate to served directory for REPOSITORY, optionally at specified PORT."
  (let ((port (or port 8888)))
    (browse-url (format "http://localhost:%s/%szoomable.html" port (f-filename repository))))
  (sleep-for 1)
  repository)

(defun c/run-server (repository &optional port)
  "Serve directory for REPOSITORY, optionally at PORT."
  (let ((httpd-host 'local)
        (httpd-port (or port 8888)))
    (httpd-stop)
    (ignore-errors (httpd-serve-directory  (format "/tmp/%s/" (f-filename repository)))))
  repository)

(defun c/run-server-and-navigate (repository &optional port)
  "Serve and navigate to REPOSITORY, optionally at PORT."
  (when port
    (c/run-server repository port)
    (c/navigate-to-localhost repository port)))

(defun c/async-run (command repository date &optional port do-not-serve)
  "Run asynchronously COMMAND taking a REPOSITORY and a DATE, optionally at PORT."
  (async-start
   `(lambda ()
      (setq load-path ',load-path)
      (load-file ,(symbol-file command))
      (let ((browse-url-browser-function 'browse-url-generic)
            (browse-url-generic-program ,c/preferred-browser))
        (funcall ',command ,repository ,date)))
   `(lambda (result)
      (let ((browse-url-browser-function 'browse-url-generic)
            (browse-url-generic-program ,c/preferred-browser))
        (when (not ,do-not-serve) (c/run-server-and-navigate (if (eq ',command 'c/show-hotspot-cluster-sync) "system" ,repository) (or ,port 8888)))))))

(defun c/show-hotspots-sync (repository date &optional port)
  "Show REPOSITORY enclosure diagram for hotspots starting at DATE, optionally served at PORT."
  (interactive
   (list
    (read-directory-name "Choose git repository directory:" (vc-root-dir))
    (call-interactively 'c/request-date)))
  (--> repository
       (c/produce-git-report it date)
       c/produce-code-maat-revisions-report
       c/produce-cloc-report
       c/generate-merger-script
       c/generate-d3-lib
       c/produce-json
       c/generate-host-enclosure-diagram-html
       (c/run-server-and-navigate it port)))

(defun c/show-hotspots (repository date &optional port)
  "Show REPOSITORY enclosure diagram for hotspots. Starting DATE reduces scope of Git log and PORT defines where the html is served."
  (interactive
   (list
    (read-directory-name "Choose git repository directory:" (vc-root-dir))
    (call-interactively 'c/request-date)))
  (c/async-run 'c/show-hotspots-sync repository date port))

(defun c/show-hotspot-snapshot-sync (repository)
  "Snapshot COMMAND over REPOSITORY over the last year every three months."
  (interactive
   (list
    (read-directory-name "Choose git repository directory:" (vc-root-dir))))
  (--each c/snapshot-periods (c/show-hotspots-sync repository (c/request-date it) 8888)))

;; BEGIN indentation

(defun c/split-on-newlines (code)
  "Split CODE over newlines."
  (s-split "\n" code))

(defun c/remove-empty-lines (lines)
  "Remove empty LINES."
  (--remove (eq (length (s-trim it)) 0) lines))

(defun c/remove-text-after-indentation (lines)
  "Remove text in LINES."
  (--map
   (apply 'string (--take-while (or (eq ?\s  it) (eq ?\t it)) (string-to-list it)))
   lines))

(defun c/find-indentation (lines-without-text)
  "Infer indentation level in LINES-WITHOUT-TEXT. If no indentation present in file, defaults to 2."
  (or (--> lines-without-text
           (--map (list (s-count-matches "\s" it) (s-count-matches "\t" it)) it)
           (let ((spaces-ind (-sort '< (--remove (eq 0 it) (-map 'c/first it))))
                 (tabs-ind (-sort '< (--remove (eq 0 it) (-map 'c/second it)))))
             (if (> (length spaces-ind) (length tabs-ind))
                 (c/first spaces-ind)
               (c/first tabs-ind))))
      2))

(defun c/convert-tabs-to-spaces (line-without-text n)
  "Replace tabs in LINE-WITHOUT-TEXT with N spaces."
  (s-replace "\t" (make-string n ?\s) line-without-text))

(defun c/calculate-complexity (line-without-text indentation)
  "Calculate indentation complexity by dividing length of LINE-WITHOUT-TEXT by INDENTATION."
  (/ (+ 0.0 (length line-without-text)) indentation))

(defun c/as-logical-indents (lines &optional opts)
  "Calculate logical indentations of LINES. Try to infer how many space is an indent unless OPTS provides it."
  (let ((indentation (or opts (c/find-indentation lines))))
   (list
     (--map
      (--> it
           (c/convert-tabs-to-spaces it indentation)
           (c/calculate-complexity it indentation))
      lines)
     indentation)))

(defun c/stats-from (complexities-indentation)
  "Return stats from COMPLEXITIES-INDENTATION."
  (let* ((complexities (c/first complexities-indentation))
         (mean (/ (-sum complexities) (length complexities)))
         (sd (sqrt (/ (-sum (--map (expt (- it mean) 2) complexities)) (length complexities)))))
    `((total . ,(-sum complexities))
      (n-lines . ,(length complexities))
      (max . ,(-max complexities))
      (mean . ,mean)
      (standard-deviation . ,sd)
      (used-indentation . ,(c/second complexities-indentation)))))

(defun c/calculate-complexity-stats (code &optional opts)
  "Return complexity of CODE based on indentation. If OPTS is provided, use these settings to define what is the indentation."
  (--> code
       ;; TODO maybe add line numbers, so that I can also open the most troublesome (max-c) line automatically?
       c/split-on-newlines
       c/remove-empty-lines
       c/remove-text-after-indentation
       (c/as-logical-indents it opts)
       c/stats-from))

(defun c/calculate-complexity-current-buffer (&optional indentation)
  "Calculate complexity of the current buffer contents.
Optionally you can provide the INDENTATION level of the file. The
code can infer it automatically."
  (interactive)
  (message "%s"
           (c/calculate-complexity-stats
            (buffer-substring-no-properties (point-min) (point-max)) indentation)))

;; END indentation

;; BEGIN complexity over commits

(defun c/retrieve-commits-up-to-date-touching-file (file &optional date)
  "Retrieve list of commits touching FILE from DATE."
  (s-split
   "\n"
   (shell-command-to-string
    (s-concat
     "git log --format=format:%H --reverse "
     (if date
         (s-concat "--after=" date " ")
       "")
     file))))

(defun c/retrieve-file-at-commit-with-git (file commit)
  "Retrieve FILE contents at COMMIT."
  (let ((git-file
         (s-join
          "/"
          (cdr
           (--drop-while
            (not
             (string= it (c/third (reverse (s-split "/" (magit-git-dir))))))
            (s-split "/" file))))))
    (shell-command-to-string (format "git show %s:\"%s\"" commit git-file))))

(defun c/git-hash-to-date (commit)
  "Return the date of the COMMIT. Note this is the date of merging in, not of the code change."
  (s-replace "\n" "" (shell-command-to-string (s-concat "git show --no-patch --no-notes --pretty='%cd' --date=short " commit))))

(defun c/calculate-complexity-over-commits (file &optional opts)
  (--> (call-interactively 'c/request-date)
       (c/retrieve-commits-up-to-date-touching-file file it)
       (--map
        (--> it
             (list it (c/retrieve-file-at-commit-with-git file it))
             (list (c/first it) (c/calculate-complexity-stats (c/second it) opts)))
        it)))

(defun c/plot-csv-file-with-graph-cli (file)
  "Plot CSV FILE with graph-cli."
  (shell-command
   (format "graph %s" file)))

(defun c/plot-lines-with-graph-cli (data)
  "Plot DATA from lists as a graph."
  (let ((tmp-file "/tmp/data-file-graph-cli.csv"))
    (with-temp-file tmp-file
      (insert "commit-date,total-complexity,loc\n")
      (insert (s-join "\n" (--map (s-replace-all '((" " . ",") ("(" . "") (")" . "")) (format "%s" it)) data))))
    (c/plot-csv-file-with-graph-cli tmp-file)))

(defun c/show-complexity-over-commits (file &optional opts)
  "Make a graph plotting complexity out of a FILE. Optionally give file indentation in OPTS."
  (interactive (list (read-file-name "Select file:" nil nil nil (buffer-file-name))))
  (c/plot-lines-with-graph-cli
   (--map
    (list (c/git-hash-to-date (c/first it)) (alist-get 'total (c/second it)) (alist-get 'n-lines (c/second it)))
    (c/calculate-complexity-over-commits file opts))))

;; END complexity over commits

;; BEGIN code churn
(defun c/produce-code-maat-abs-churn-report (repository)
  "Create code-maat abs-churn report for REPOSITORY."
  (c/run-code-maat "abs-churn" repository)
  repository)

(defun c/show-code-churn-sync (repository date)
  "Show how much code was added and removed from REPOSITORY from a DATE."
  (interactive (list
                (read-directory-name "Choose git repository directory:" (vc-root-dir))
                (call-interactively 'c/request-date)))
  (--> repository
       (c/produce-git-report it date)
       c/produce-code-maat-abs-churn-report
       (format"/tmp/%s-abs-churn.csv" (f-filename it))
       c/plot-csv-file-with-graph-cli))

(defun c/show-code-churn (repository date)
  "Show how much code was added and removed from REPOSITORY from a DATE."
  (interactive (list
                (read-directory-name "Choose git repository directory:" (vc-root-dir))
                (call-interactively 'c/request-date)))
  (c/async-run 'c/show-code-churn-sync repository date nil 't))
;; END complexity over commits

;; BEGIN change coupling
(defun c/produce-code-maat-coupling-report (repository)
  "Create code-maat coupling report for REPOSITORY."
  (c/run-code-maat "coupling" repository)
  repository)

(defun c/generate-coupling-json-script (repository)
  "Generate script to produce a weighted graph for REPOSITORY."
  (with-temp-file "/tmp/coupling_csv_as_edge_bundling.py"
    (insert
     "## The input data is read from a Code Maat CSV file containing the result
## of a <coupling> analysis.
#######################################################################

import argparse
import csv
import json
import sys

######################################################################
## Parse input
######################################################################

def validate_content_by(heading, expected):
        if not expected:
                return # no validation
        comparison = expected.split(',')
        stripped = heading[0:len(comparison)] # allow extra fields
        if stripped != comparison:
                raise MergeError('Erroneous content. Expected = ' + expected + ', got = ' + ','.join(heading))

def parse_csv(filename, parse_action, expected_format=None):
        def read_heading_from(r):
                p = next(r)
                while p == []:
                        p = next(r)
                return p
        with open(filename, 'rt', encoding=\"utf8\") as csvfile:
                r = csv.reader(csvfile, delimiter=',')
                heading = read_heading_from(r)
                validate_content_by(heading, expected_format)
                return [parse_action(row) for row in r]

class LinkBetweenCoupled(object):
        def __init__(self, entity, coupled, degree):
                self.entity = entity
                self.coupled = coupled
                self.degree = int(degree)

def parse_coupleds(csv_row):
        return LinkBetweenCoupled(csv_row[0], csv_row[1], csv_row[2]) # 2020-07-05 AG: editing this to make it work with software dependencies, TODO rename all entity based naming to coupled stuff

######################################################################
## Assemble the individual entries into an aggregated structure
######################################################################

def link_to(existing_entitys, new_link):
        if not new_link.entity in existing_entitys:
                return {'name':new_link.entity, 'size':new_link.degree, 'imports':[new_link.coupled]}
        existing_entity = existing_entitys[new_link.entity]
        existing_entity['imports'].append(new_link.coupled)
        existing_entity['size'] = existing_entity['size'] + new_link.degree
        return existing_entity

def aggregate_links_per_entity_in(coupled_links):
        links_per_entity = {}
        for coupled in coupled_links:
                links_per_entity[coupled.entity] = link_to(links_per_entity, coupled)
        return links_per_entity

######################################################################
## Output
######################################################################

def write_json(result):
        print(json.dumps(result))

######################################################################
## Main
######################################################################

def run(args):
        coupled_links = parse_csv(args.coupling,
                                                        expected_format='entity,coupled,degree,average-revs',
                                                        parse_action=parse_coupleds)
        links_by_entity = aggregate_links_per_entity_in(coupled_links)
        write_json(list(links_by_entity.values()))

if __name__ == \"__main__\":
        parser = argparse.ArgumentParser(description='Generates a JSON document suitable for coupling diagrams.')
        parser.add_argument('--coupling', required=True, help='A CSV file containing the result of a coupling analysis')

        args = parser.parse_args()
        run(args)

     "))
  repository)

(defun c/produce-coupling-json (repository)
  "Produce coupling json needed by d3 for REPOSITORY."
  (message "Produce coupling json...")
  (shell-command
   (format
    "cd /tmp; python3 coupling_csv_as_edge_bundling.py --coupling %s-coupling.csv > /tmp/%s/%s-edgebundling.json"
    (f-filename repository)
    (f-filename repository)
    (f-filename repository)
    (f-filename repository)))
  repository)


(defun c/generate-host-edge-bundling-html (repository)
  "Generate host html from REPOSITORY."
  (with-temp-file (format "/tmp/%s/%szoomable.html" (f-filename repository) (f-filename repository))
    (insert
     (concat
      "<!DOCTYPE html>
<meta charset=\"utf-8\">
<style>

.node {
  font: 300 11px \"Helvetica Neue\", Helvetica, Arial, sans-serif;
  fill: #bbb;
}

.node:hover {
  fill: #000;
}

.link {
  stroke: steelblue;
  stroke-opacity: 0.4;
  fill: none;
  pointer-events: none;
}

.node:hover,
.node--source,
.node--target {
  font-weight: 700;
}

.node--source {
  fill: #2ca02c;
}

.node--target {
  fill: #d62728;
}

.link--source,
.link--target {
  stroke-opacity: 1;
  stroke-width: 2px;
}

.link--source {
  stroke: #d62728;
}

.link--target {
  stroke: #2ca02c;
}

</style>
<body>
<script src=\"d3/d3-v4.min.js\"></script>
<script>

var diameter = 960,
    radius = diameter / 2,
    innerRadius = radius - 120;

var cluster = d3.cluster()
    .size([360, innerRadius]);

var line = d3.radialLine()
    .curve(d3.curveBundle.beta(0.85))
    .radius(function(d) { return d.y; })
    .angle(function(d) { return d.x / 180 * Math.PI; });

var svg = d3.select(\"body\").append(\"svg\")
    .attr(\"width\", diameter)
    .attr(\"height\", diameter)
  .append(\"g\")
    .attr(\"transform\", \"translate(\" + radius + \",\" + radius + \")\");

var link = svg.append(\"g\").selectAll(\".link\"),
    node = svg.append(\"g\").selectAll(\".node\");

d3.json(\""
      (f-filename repository)
      "-edgebundling.json\", function(error, classes) {
  if (error) throw error;

  var root = packageHierarchy(classes)
      .sum(function(d) { return d.size; });

  cluster(root);

  link = link
    .data(packageImports(root.leaves()))
    .enter().append(\"path\")
      .each(function(d) { d.source = d[0], d.target = d[d.length - 1]; })
      .attr(\"class\", \"link\")
      .attr(\"d\", line);

  node = node
    .data(root.leaves())
    .enter().append(\"text\")
      .attr(\"class\", \"node\")
      .attr(\"dy\", \"0.31em\")
      .attr(\"transform\", function(d) { return \"rotate(\" + (d.x - 90) + \")translate(\" + (d.y + 8) + \",0)\" + (d.x < 180 ? \"\" : \"rotate(180)\"); })
      .attr(\"text-anchor\", function(d) { return d.x < 180 ? \"start\" : \"end\"; })
      .text(function(d) { return d.data.key; })
      .on(\"mouseover\", mouseovered)
      .on(\"mouseout\", mouseouted);
});

function mouseovered(d) {
  node
      .each(function(n) { n.target = n.source = false; });

  link
      .classed(\"link--target\", function(l) { if (l.target === d) return l.source.source = true; })
      .classed(\"link--source\", function(l) { if (l.source === d) return l.target.target = true; })
    .filter(function(l) { return l.target === d || l.source === d; })
      .raise();

  node
      .classed(\"node--target\", function(n) { return n.target; })
      .classed(\"node--source\", function(n) { return n.source; });
}

function mouseouted(d) {
  link
      .classed(\"link--target\", false)
      .classed(\"link--source\", false);

  node
      .classed(\"node--target\", false)
      .classed(\"node--source\", false);
}

// Lazily construct the package hierarchy from class names.
function packageHierarchy(classes) {
  var map = {};

  function find(name, data) {
    var node = map[name], i;
    if (!node) {
      node = map[name] = data || {name: name, children: []};
      if (name.length) {
        node.parent = find(name.substring(0, i = name.lastIndexOf(\"/\")));
        node.parent.children.push(node);
        node.key = name.substring(i + 1);
      }
    }
    return node;
  }

  classes.forEach(function(d) {
    find(d.name, d);
  });

  return d3.hierarchy(map[\"\"]);
}

// Return a list of imports for the given array of nodes.
function packageImports(nodes) {
  var map = {},
      imports = [];

  // Compute a map from name to node.
  nodes.forEach(function(d) {
    map[d.data.name] = d;
  });

  // For each import, construct a link from the source to target node.
  nodes.forEach(function(d) {
    if (d.data.imports) d.data.imports.forEach(function(i) {
      if (map[i]) { // skip nodes that do not have a pair
      imports.push(map[d.data.name].path(map[i]));
    }});
  });

  return imports;
}

</script>
")))
  repository)

(defun c/show-coupling-graph-sync (repository date &optional port)
  "Show REPOSITORY edge bundling synchronously for code coupling up to DATE. Serve graph on PORT."
  (interactive (list
                (read-directory-name "Choose git repository directory:" (vc-root-dir))
                (call-interactively 'c/request-date)))
  (--> repository
       (c/produce-git-report it nil date)
       c/produce-code-maat-coupling-report
       c/generate-coupling-json-script
       c/generate-d3-v4-lib
       c/produce-coupling-json
       c/generate-host-edge-bundling-html
       (c/run-server-and-navigate it port)))

(defun c/show-coupling-graph (repository date &optional port)
  "Show REPOSITORY edge bundling for code coupling up to DATE. Serve graph on PORT."
  (interactive (list
                (read-directory-name "Choose git repository directory:" (vc-root-dir))
                (call-interactively 'c/request-date)))
  (c/async-run 'c/show-coupling-graph-sync repository date port))
;; END change coupling

(provide 'code-compass)
;;; code-compass ends here

;; Local Variables:
;; time-stamp-pattern: "10/Version:\\?[ \t]+1.%02y%02m%02d\\?\n"
;; End:
