##  File src/library/tools/R/doitools.R
##  Part of the R package, https://www.R-project.org
##
##  Copyright (C) 2015 The R Core Team
##
##  This program is free software; you can redistribute it and/or modify
##  it under the terms of the GNU General Public License as published by
##  the Free Software Foundation; either version 2 of the License, or
##  (at your option) any later version.
##
##  This program is distributed in the hope that it will be useful,
##  but WITHOUT ANY WARRANTY; without even the implied warranty of
##  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
##  GNU General Public License for more details.
##
##  A copy of the GNU General Public License is available at
##  https://www.R-project.org/Licenses/

.get_dois_from_Rd <-
function(x)
{
    dois <- character()
    recurse <- function(e) {
        tag <- attr(e, "Rd_tag")
        if(identical(tag, "\\doi")) {
            dois <<-
                c(dois,
                  trimws(gsub("\n", "", .Rd_deparse(e, tag = FALSE),
                              fixed = TRUE, useBytes = TRUE)))
        }
    }
    lapply(x, recurse)
    unique(trimws(dois))
}

doi_db <-
function(dois, parents)
{
    db <- data.frame(DOI = trimws(as.character(dois)),
                     Parent = as.character(parents),
                     stringsAsFactors = FALSE)
    class(db) <- c("doi_db", "data.frame")
    db
}

doi_db_from_package_Rd_db <-
function(db)
{
    dois <- Filter(length, lapply(db, .get_dois_from_Rd))
    doi_db(unlist(dois, use.names = FALSE),
           rep.int(file.path("man", names(dois)),
                   lengths(dois)))
}
    
doi_db_from_package_citation <-
function(dir, meta, installed = FALSE)
{
    dois <- character()
    path <- if(installed) "CITATION" else file.path("inst", "CITATION")
    cfile <- file.path(dir, path)
    if(file.exists(cfile)) {
        cinfo <- .read_citation_quietly(cfile, meta)
        if(!inherits(cinfo, "error"))
            dois <- trimws(unique(unlist(cinfo$doi, use.names = FALSE)))
    }
    doi_db(dois, rep.int(path, length(dois)))
}

doi_db_from_package_sources <-
function(dir, add = FALSE)    
{
    meta <- .read_description(file.path(dir, "DESCRIPTION"))
    db <- rbind(doi_db_from_package_Rd_db(Rd_db(dir = dir)),
                doi_db_from_package_citation(dir, meta))
    if(add)
        db$Parent <- file.path(basename(dir), db$Parent)
    db
}

doi_db_from_installed_packages <-
function(packages, lib.loc = NULL, verbose = FALSE)
{
    if(!length(packages)) return()
    one <- function(p) {
        if(verbose)
            message(sprintf("processing %s", p))
        dir <- system.file(package = p, lib.loc = lib.loc)
        if(dir == "") return()
        meta <- .read_description(file.path(dir, "DESCRIPTION"))
        rddb <- Rd_db(p, lib.loc = dirname(dir))
        db <- rbind(doi_db_from_package_Rd_db(rddb),
                    doi_db_from_package_citation(dir, meta,
                                                 installed = TRUE))
        db$Parent <- file.path(p, db$Parent)
        db
    }
    do.call(rbind,
            c(lapply(packages, one),
              list(make.row.names = FALSE)))
}

check_doi_db <-
function(db, verbose = FALSE)
{
    .gather <- function(d = character(),
                        p = list(),
                        s = rep.int("", length(d)),
                        m = rep.int("", length(d))) {
        y <- data.frame(DOI = d, From = I(p), Status = s, Message = m,
                        stringsAsFactors = FALSE)
        y$From <- p
        class(y) <- c("check_doi_db", "data.frame")
        y
    }

    .fetch <- function(d) {
        if(verbose) message(sprintf("processing %s", d))
        u <- paste0("http://doi.org/", d)
        ## Do we need to percent encode parts of the DOI name?
        tryCatch(curlGetHeaders(u), error = identity)
    }

    .check <- function(d) {
        h <- .fetch(d)
        if(inherits(h, "error")) {
            s <- "-1"
            msg <- sub("[[:space:]]*$", "", conditionMessage(h))
        } else {
            s <- as.character(attr(h, "status"))
            msg <- table_of_HTTP_status_codes[s]
        }
        ## Similar to URLs, see e.g.
        ##   curl -I -L http://doi.org/10.1016/j.csda.2009.12.005
        if(any(grepl("301 Moved Permanently", h, useBytes = TRUE))) {
            ind <- grep("^[Ll]ocation: ", h, useBytes = TRUE)
            new <- sub("^[Ll]ocation: ([^\r]*)\r\n", "\\1", h[max(ind)])
            if((s == "503") && grepl("www.sciencedirect.com", new))
                s <- "405"
        }
        c(s, msg)
    }

    bad <- .gather()

    if(!NROW(db)) return(bad)

    parents <- split(db$Parent, db$DOI)
    dois <- names(parents)

    ## See <https://www.doi.org/doi_handbook/2_Numbering.html#2.2>:
    ##   The DOI prefix shall be composed of a directory indicator
    ##   followed by a registrant code. These two components shall be
    ##   separated by a full stop (period).
    ##   The directory indicator shall be "10".
    ind <- !grepl("^10", dois)
    if(any(ind)) {
        len <- sum(ind)
        bad <- rbind(bad,
                     .gather(dois[ind],
                             parents[ind],
                             m = rep.int("Invalid DOI", len)))
    }

    pos <- which(!ind)
    if(length(pos)) {
        results <- do.call(rbind, lapply(dois[pos], .check))
        status <- as.numeric(results[, 1L])
        ind <- !(status %in% c(200L, 405L))
        if(any(ind)) {
            pos <- pos[ind]
            s <- as.character(status[ind])
            s[s == "-1"] <- "Error"
            m <- results[ind, 2L]
            m[is.na(m)] <- ""
            bad <- rbind(bad,
                         .gather(dois[pos],
                                 parents[pos],
                                 m,
                                 s))
        }
    }

    bad
}

format.check_doi_db <-
function(x, ...)
{
    if(!NROW(x)) return(character())

    paste0(sprintf("DOI: %s", x$DOI),
           sprintf("\nFrom: %s",
                   sapply(x$From, paste, collapse = "\n      ")),
           ifelse((s <- x$Status) == "",
                  "",
                  sprintf("\nStatus: %s", s)),
           ifelse((m <- x$Message) == "",
                  "",
                  sprintf("\nMessage: %s", m)))
}

print.check_doi_db <-
function(x, ...)
{
    if(NROW(x))
        writeLines(paste(format(x), collapse = "\n\n"))
    invisible(x)
}
