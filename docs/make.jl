using Documenter
using ReproducibleJobs

DocMeta.setdocmeta!(ReproducibleJobs, :DocTestSetup, :(using ReproducibleJobs); recursive=true)

makedocs(;
	modules = [ReproducibleJobs],
	authors = "Rasmus Henningsson <rasmus.henningsson@gmail.com>",
	repo = Remotes.GitHub("rasmushenningsson", "ReproducibleJobs.jl"),
	sitename = "ReproducibleJobs.jl",
	format = Documenter.HTML(;
		prettyurls = get(ENV, "CI", "false") == "true",
		canonical = "https://rasmushenningsson.github.io/ReproducibleJobs.jl",
		edit_link = "main",
		assets = String[],
	),
	pages=[
		"Home" => "index.md",
		"User Guide" => "userguide.md",
		"Interface" => "interface.md",
	],
)

deploydocs(;
	repo="github.com/rasmushenningsson/ReproducibleJobs.jl",
	devbranch="main",
)
