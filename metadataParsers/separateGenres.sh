awk -F\\t 'BEGIN{OFS="\t"}{match($6, "\\."); if (RSTART > 0) {str1=substr($6, 0, RSTART-1); str2=substr($6,RSTART+1);} else {str1=$6; str2=$6;} print $1,str1,str2;}' ../../metadata.txt > ../../genre.txt
