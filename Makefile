NAME = riscv-abi

DATE = $(shell date '+%B %d, %Y')
MONTHYEAR = $(shell date '+%B %Y')

.PHONY: all
all: $(NAME).pdf

.PHONY: clean
clean:
	rm -f $(NAME).pdf

$(NAME).pdf: $(NAME).adoc $(wildcard *.adoc) resources/themes/risc-v_spec-pdf.yml
	asciidoctor-pdf \
	    -a compress \
	    -a date="$(DATE)" \
	    -a monthyear="$(MONTHYEAR)" \
	    -a pdf-style=resources/themes/risc-v_spec-pdf.yml \
	    -a pdf-fontsdir=resources/fonts \
	    -v \
	    $< -o $@

regen_vector_type_infos:
	python3 gen_vector_type_infos.py > vector_type_infos.adoc
