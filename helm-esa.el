;;; helm-esa.el --- esa with helm interface -*- lexical-binding: t; -*-

;; Copyright (C) 2019 by Takashi Masuda

;; Author: Takashi Masuda <masutaka.net@gmail.com>
;; URL: https://github.com/masutaka/emacs-helm-esa
;; Version: 1.0.0
;; Package-Requires: ((emacs "24") (helm "3.2"))

;; This program is free software: you can redistribute it and/or modify
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
;; helm-esa.el provides a helm interface to esa (https://esa.io/).

;;; Code:

(require 'helm)
(require 'json)

(defgroup helm-esa nil
  "esa with helm interface"
  :prefix "helm-esa-"
  :group 'helm)

(defcustom helm-esa-team-name nil
  "A name of your esa team name."
  :type '(choice (const nil)
		 string)
  :group 'helm-esa)

(defcustom helm-esa-access-token nil
  "Your esa access token.
You can create on https://{team_name}.esa.io/user/applications
The required scope is `Read`."
  :type '(choice (const nil)
		 string)
  :group 'helm-esa)

(defcustom helm-esa-search-query "watched:true kind:stock"
  "Query for searching esa articles.
See https://docs.esa.io/posts/104"
  :type '(choice (const nil)
		 string)
  :group 'helm-esa)

(defcustom helm-esa-file
  (expand-file-name "helm-esa" user-emacs-directory)
  "A cache file search articles with `helm-esa-search-query'."
  :type '(choice (const nil)
		 string)
  :group 'helm-esa)

(defcustom helm-esa-candidate-number-limit 100
  "Candidate number limit."
  :type 'integer
  :group 'helm-esa)

(defcustom helm-esa-interval (* 1 60 60)
  "Number of seconds to call `helm-esa-http-request'."
  :type 'integer
  :group 'helm-esa)

;;; Internal Variables

(defvar helm-esa-api-per-page 100
  "Page size of esa API.
See https://docs.esa.io/posts/102")

(defvar helm-esa-curl-program nil
  "Cache a result of `helm-esa-find-curl-program'.
DO NOT SET VALUE MANUALLY.")

(defconst helm-esa-http-buffer-name " *helm-esa-http*"
  "HTTP Working buffer name of `helm-esa-http-request'.")

(defconst helm-esa-work-buffer-name " *helm-esa-work*"
  "Working buffer name of `helm-esa-http-request'.")

(defvar helm-esa-full-frame helm-full-frame)

(defvar helm-esa-timer nil
  "Timer object for esa caching will be stored here.
DO NOT SET VALUE MANUALLY.")

(defvar helm-esa-debug-mode nil)
(defvar helm-esa-debug-start-time nil)

;;; Macro

(defmacro helm-esa-file-check (&rest body)
  "The BODY is evaluated only when `helm-esa-file' exists."
  `(if (file-exists-p helm-esa-file)
       ,@body
     (message "%s not found. Please wait up to %d minutes."
	      helm-esa-file (/ helm-esa-interval 60))))

;;; Helm source

(defun helm-esa-load ()
  "Load `helm-esa-file'."
  (helm-esa-file-check
   (with-current-buffer (helm-candidate-buffer 'global)
	(let ((coding-system-for-read 'utf-8))
	  (insert-file-contents helm-esa-file)))))

(defvar helm-esa-action
  '(("Browse URL" . helm-esa-browse-url)
    ("Show URL" . helm-esa-show-url)))

(defun helm-esa-browse-url (candidate)
  "Action for Browse URL.
Argument CANDIDATE a line string of an article."
  (string-match "\\[href:\\(.+\\)\\]" candidate)
  (browse-url (match-string 1 candidate)))

(defun helm-esa-show-url (candidate)
  "Action for Show URL.
Argument CANDIDATE a line string of a article."
  (string-match "\\[href:\\(.+\\)\\]" candidate)
  (message (match-string 1 candidate)))

(defvar helm-esa-source
  (helm-build-in-buffer-source "esa articles"
    :init 'helm-esa-load
    :action 'helm-esa-action
    :candidate-number-limit helm-esa-candidate-number-limit
    :multiline t
    :migemo t)
  "Helm source for esa.")

;;;###autoload
(defun helm-esa ()
  "Search esa articles using `helm'."
  (interactive)
  (let ((helm-full-frame helm-esa-full-frame))
    (helm-esa-file-check
     (helm :sources helm-esa-source
	   :prompt "Find esa articles: "))))

;;; Process handler

(defun helm-esa-http-request (&optional url)
  "Make a new HTTP request for create `helm-esa-file'.
Use `helm-esa-get-url' if URL is nil."
  (let ((http-buffer-name helm-esa-http-buffer-name)
	(work-buffer-name helm-esa-work-buffer-name)
	(proc-name "helm-esa")
	(curl-args `("--include" "-X" "GET" "--compressed"
		     "--header" ,(concat "Authorization: Bearer " helm-esa-access-token)
		     ,(if url url (helm-esa-get-url))))
	proc)
    (unless (get-buffer-process http-buffer-name)
      (unless url ;; 1st page
	(if (get-buffer work-buffer-name)
	    (kill-buffer work-buffer-name))
	(get-buffer-create work-buffer-name))
      (helm-esa-http-debug-start)
      (setq proc (apply 'start-process
			proc-name
			http-buffer-name
			helm-esa-curl-program
			curl-args))
      (set-process-sentinel proc 'helm-esa-http-request-sentinel))))

(defun helm-esa-http-request-sentinel (process _event)
  "Handle a response of `helm-esa-http-request'.
PROCESS is a http-request process.
_EVENT is a string describing the type of event.
If next-url is exist, requests it.
If the response is invalid, stops to request."
  (let ((http-buffer-name helm-esa-http-buffer-name))
    (condition-case nil
	(let (response-body next-url)
	  (with-current-buffer (get-buffer http-buffer-name)
	    (unless (helm-esa-valid-http-responsep process)
	      (error "Invalid http response"))
	    (setq response-body (helm-esa-response-body))
	    (setq next-url (helm-esa-next-url response-body)))
	  (kill-buffer http-buffer-name)
	  (with-current-buffer (get-buffer helm-esa-work-buffer-name)
	    (goto-char (point-max))
	    (helm-esa-insert-articles response-body)
	    (if next-url
		(helm-esa-http-request next-url)
	      (write-region (point-min) (point-max) helm-esa-file))))
      (error
       (kill-buffer http-buffer-name)))))

(defun helm-esa-valid-http-responsep (process)
  "Return if the http response is valid.
Argument PROCESS is a http-request process.
Should to call in `helm-esa-http-buffer-name'."
  (save-excursion
    (let ((result))
      (goto-char (point-min))
      (setq result (re-search-forward "^HTTP/2 200" (point-at-eol) t))
      (helm-esa-http-debug-finish result process)
      result)))

(defun helm-esa-point-of-separator ()
  "Return point between header and body of the http response, as an integer."
  (save-excursion
    (goto-char (point-min))
    (re-search-forward "^?$" nil t)))

(defun helm-esa-response-body ()
  "Read http response body as a json.
Should to call in `helm-esa-http-buffer-name'."
  (json-read-from-string
   (buffer-substring-no-properties
    (+ (helm-esa-point-of-separator) 1) (point-max))))

(defun helm-esa-insert-articles (response-body)
  "Insert esa article as the format of `helm-esa-file'.
Argument RESPONSE-BODY is http response body as a json"
  (let ((articles (helm-esa-articles response-body))
	article category name format-tags url format-article)
    (dotimes (i (length articles))
      (setq article (aref articles i)
	    category (helm-esa-article-category article)
	    name (helm-esa-article-name article)
	    format-tags (helm-esa-article-format-tags article)
	    url (helm-esa-article-url article))
      (insert
       (if category
	   (format "%s/%s %s [href:%s]\n" category name format-tags url)
	 (format "%s %s [href:%s]\n" name format-tags url))))))

(defun helm-esa-next-url (response-body)
  "Return the next page url from RESPONSE-BODY."
  (let ((next-page (helm-esa-next-page response-body)))
    (if next-page
	(helm-esa-get-url next-page))))

(defun helm-esa-next-page (response-body)
  "Return next page number from RESPONSE-BODY."
  (cdr (assoc 'next_page response-body)))

(defun helm-esa-articles (response-body)
  "Return articles from RESPONSE-BODY."
  (cdr (assoc 'posts response-body)))

(defun helm-esa-article-category (article)
  "Return a category of ARTICLE."
  (cdr (assoc 'category article)))

(defun helm-esa-article-name (article)
  "Return a name of ARTICLE."
  (cdr (assoc 'name article)))

(defun helm-esa-article-url (article)
  "Return a url of ARTICLE."
  (cdr (assoc 'url article)))

(defun helm-esa-article-format-tags (article)
  "Return formatted tags of ARTICLE."
  (let ((result ""))
    (mapc
     (lambda (tag)
       (setq result (format "%s[%s]" result tag)))
     (helm-esa-article-tags article))
    result))

(defun helm-esa-article-tags (article)
  "Return tags of ARTICLE, as an list."
  (append (cdr (assoc 'tags article)) nil))

;;; Debug

(defun helm-esa-http-debug-start ()
  "Start debug mode."
  (setq helm-esa-debug-start-time (current-time)))

(defun helm-esa-http-debug-finish (result process)
  "Stop debug mode.
RESULT is boolean.
PROCESS is a http-request process."
  (if helm-esa-debug-mode
      (message "[esa] %s to GET %s (%0.1fsec) at %s."
	       (if result "Success" "Failure")
	       (car (last (process-command process)))
	       (time-to-seconds
		(time-subtract (current-time)
			       helm-esa-debug-start-time))
	       (format-time-string "%Y-%m-%d %H:%M:%S" (current-time)))))

;;; Timer

(defun helm-esa-set-timer ()
  "Set timer."
  (setq helm-esa-timer
	(run-at-time "0 sec"
		     helm-esa-interval
		     #'helm-esa-http-request)))

(defun helm-esa-cancel-timer ()
  "Cancel timer."
  (when helm-esa-timer
    (cancel-timer helm-esa-timer)
    (setq helm-esa-timer nil)))

;;;###autoload
(defun helm-esa-initialize ()
  "Initialize `helm-esa'."
  (unless helm-esa-team-name
    (error "Variable `helm-esa-team-name' is nil"))
  (unless helm-esa-access-token
    (error "Variable `helm-esa-access-token' is nil"))
  (setq helm-esa-curl-program
	(helm-esa-find-curl-program))
  (helm-esa-set-timer))

(defun helm-esa-get-url (&optional page)
  "Return esa API endpoint for searching articles.
PAGE is a natural number.  If it doesn't set, it equal to 1."
  (format "https://api.esa.io/v1/teams/%s/posts?q=%s&page=%d&per_page=%d"
	  helm-esa-team-name
	  (url-hexify-string helm-esa-search-query)
	  (if page page 1)
	  helm-esa-api-per-page))

(defun helm-esa-find-curl-program ()
  "Return an appropriate `curl' program pathname or error if not found."
  (or
   (executable-find "curl")
   (error "Cannot find `curl' helm-esa.el requires")))

(provide 'helm-esa)

;;; helm-esa.el ends here
