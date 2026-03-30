# AI Usage Process
This project was built with the help of AI tools (Claude Code)

1. Filter code was written with MATLAB Documentation and the csv file was exported.
2. Asked Claude to add comments for explanations.
3. Used Claude to find options for quantization methods that are useful for this case and selected Q1.15 quantization method.
4. Using the quantization method wrote a script and modified it to make it more robust in generating ROM module in system verilog.
5. Once the ROM us generated, asked Claude to make a plan on implementing a filter with the plan using an FSM. Claude made a plan which needed some corrections (*e.g.,* asynchronous design which would cause timing error when synchronizing data from ROM). With the corrections asked Claude to write the design in *systemverilog*.
6. The *systemverilog* implementations had several issues (e.g., not interfacing the modules correctly, using syntaxes that are not supported by Vivado etc.).
