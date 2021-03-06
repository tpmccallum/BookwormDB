#invoke with any of these variable: eg, `make`

textStream:=scripts/justPrintInputTxt.sh

# The maximum size of each input block for parallel processing.
# 100M should be appropriate for a machine with 8-16GB of memory: if you're
# having problems on a smaller machine, try bringing it down.

blockSize:=100M

webDirectory=/var/www/

#New syntax requires bash
SHELL:=/bin/bash

#You can manually specify a bookworm name, but normally it just greps it out of your configuration file.
bookwormName:=$(shell grep database bookworm.cnf | sed 's/.* = //g')

#The data format may vary depending on how the raw files are stored. The easiest way is to simply pipe out the contents from input.txt: but any other method that produces the same format (a python script that unzips from a directory with an arcane structure, say) is just as good.
#The important thing, I think, is that it not insert EOF markers into the middle of your stream.

webSite = $(addsuffix bookwormName,webDirectory)

all: bookworm.cnf files/targets files/targets/database

bookworm.cnf:
	python scripts/makeConfiguration.py

#These are all directories that need to be in place for the other scripts to work properly
files/targets: 
	#"-building needed directories"
	@mkdir -p files/texts
	@mkdir -p files/texts/encoded/{unigrams,bigrams,trigrams,completed}
	@mkdir -p files/texts/{textids,wordlist}
	@mkdir -p files/targets

#A "make clean" removes most things created by the bookworm,
#but keeps the database and the registry of text and wordids

clean:
#Remove inputs.txt if it's a pipe.
	find files/texts -maxdepth 1 -type p -delete
	rm -rf files/texts/encoded/*/*
	rm -rf files/targets
	rm -f files/metadata/catalog.txt
	rm -f files/metadata/jsoncatalog_derived.txt
	rm -f files/metadata/field_descriptions_derived.json

# Make 'pristine' is a little more aggressive
# This can be dangerous, but lets you really wipe the slate.

pristine: clean
	-mysql -e "DROP DATABASE $(bookwormName)"
	rm -rf files/texts/textids
	rm -rf files/texts/wordlist/*

# The wordlist is an encoding scheme for words: it tokenizes in parallel, and should
# intelligently update an exist vocabulary where necessary. It takes about half the time
# just to build this: any way to speed it up is a huge deal.
# The easiest thing to do, of course, is simply use an Ngrams or other wordlist.

# The build method is dependent on whether we're using an accumulated wordcount list
# from elsewhere. If so, we use Peter Organisciak's fast_featurecounter.sh on that, instead.

ifneq ("$(wildcard ../unigrams.txt)","")
wordlistBuilder=scripts/fast_featurecounter.sh ../unigrams.txt /tmp $(blockSize) files/texts/wordlist/sorted.txt; head -1000000 files/texts/wordlist/sorted.txt > files/texts/wordlist/wordlist.txt
else
wordlistBuilder=$(textStream) | parallel --block-size $(blockSize) --pipe python bookworm/printTokenStream.py | python bookworm/wordcounter.py
endif

files/texts/wordlist/wordlist.txt:
	$(wordlistBuilder)



# This invokes OneClick on the metadata file to create a more useful internal version
# (with parsed dates) and to create a lookup file for textids in files/texts/textids

files/metadata/jsoncatalog_derived.txt: files/metadata/jsoncatalog.txt files/metadata/field_descriptions.json
#Run through parallel as well.
	cat files/metadata/jsoncatalog.txt | parallel --pipe python bookworm/MetaParser.py > $@


# In addition to building files for ingest.

files/metadata/catalog.txt:
	python OneClick.py preDatabaseMetadata

# This is the penultimate step: creating a bunch of tsv files 
# (one for each binary blob) with 3-byte integers for the text
# and word IDs that MySQL can slurp right up.

# This could be modified to take less space/be faster by using named pipes instead
# of pre-built files inside the files/targets/encoded files: it might require having
# hundreds of blocked processes simultaneously, though, so I'm putting that off for now.

# The tokenization script dispatches a bunch of parallel processes to bookworm/tokenizer.py,
# each of which saves a binary file. The cat stage at the beginning here could be modified to 
# check against some list that tracks which texts we have already encoded to allow additions to existing 
# bookworms to not require a complete rebuild.



#Use an alternate method to ingest feature counts if the file is defined immediately below.

ifneq ("$(wildcard ../unigrams.txt)","")
encoder=cat ../unigrams.txt | parallel --block-size $(blockSize) -u --pipe python bookworm/ingestFeatureCounts.py encode
else
encoder=$(textStream) | parallel --block-size $(blockSize) -u --pipe python bookworm/tokenizer.py
endif

files/targets/encoded: files/texts/wordlist/wordlist.txt
#builds up the encoded lists that don't exist yet.
#I "Make" the catalog files rather than declaring dependency so that changes to 
#the catalog don't trigger a db rebuild automatically.
	make files/metadata/jsoncatalog_derived.txt
	make files/texts/textids.dbm
	make files/metadata/catalog.txt
	$(encoder)
	touch files/targets/encoded

# The database is the last piece to be built: this invocation of OneClick.py
# uses the encoded files already written to disk, and loads them into a database.
# It also throws out a few other useful files at the end into files/

files/targets/database: files/targets/database_wordcounts files/targets/database_metadata 
	touch $@

files/texts/textids.dbm: files/texts/textids files/metadata/jsoncatalog_derived.txt files/metadata/catalog.txt
	python bookworm/makeWordIdDBM.py

files/targets/database_metadata: files/targets/encoded files/texts/wordlist/wordlist.txt files/targets/database_wordcounts files/metadata/jsoncatalog_derived.txt files/metadata/catalog.txt 
	python OneClick.py database_metadata
	touch $@

files/targets/database_wordcounts: files/targets/encoded files/texts/wordlist/wordlist.txt
	python OneClick.py database_wordcounts
	touch $@

# the bookworm json is created as a sideeffect of the database creation: this just makes that explicit for the webdirectory target.
# I haven't yet gotten Make to properly just handle the shuffling around: maybe a python script inside "etc" would do better.

$(webDirectory)/$(bookwormName):
	git clone https://github.com/Bookworm-project/BookwormGUI $@

linechartGUI: $(webDirectory)/$(bookwormName) files/$(bookwormName).json
	cp files/$(bookwormName).json $</static/options.json


### Some defaults to make it easier to clone this directory in:

files/metadata/jsoncatalog.txt:
	mkdir -p files/metadata
	ln -sf ../../../jsoncatalog.txt $@


files/metadata/field_descriptions.json:
	mkdir -p files/metadata
	@if [ -f ../field_descriptions.json ]; then \
		ln -sf ../../../field_descriptions.json files/metadata/field_descriptions.json; \
	fi

