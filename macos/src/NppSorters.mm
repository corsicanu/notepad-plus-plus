// Upstream's line sorters (MISC/Common/Sorters.h), compiled unchanged, plus
// the two Common.cpp helpers they need.
#include <windows.h>
#include <stdexcept>
#include <string>
#include <vector>

std::wstring stringTakeWhileAdmissable(const std::wstring& input, const std::wstring& admissable);
double stodLocale(const std::wstring& str, _locale_t loc, size_t* idx = nullptr);
std::wstring stringReplace(std::wstring subject, const std::wstring& search, const std::wstring& replace);

#include "Sorters.h"
#include "NppSorters.h"

std::wstring stringTakeWhileAdmissable(const std::wstring& input, const std::wstring& admissable)
{
	size_t idx = input.find_first_not_of(admissable);
	return idx == std::wstring::npos ? input : input.substr(0, idx);
}

std::wstring stringReplace(std::wstring subject, const std::wstring& search, const std::wstring& replace)
{
	size_t pos = 0;
	while ((pos = subject.find(search, pos)) != std::wstring::npos)
	{
		subject.replace(pos, search.length(), replace);
		pos += replace.length();
	}
	return subject;
}

double stodLocale(const std::wstring& str, _locale_t loc, size_t* idx)
{
	const wchar_t* ptr = str.c_str();
	errno = 0;
	wchar_t* eptr;
	double ans = ::_wcstod_l(ptr, &eptr, loc);
	if (ptr == eptr)
		throw std::invalid_argument("invalid stod argument");
	if (errno == ERANGE)
		throw std::out_of_range("stod argument out of range");
	if (idx)
		*idx = static_cast<size_t>(eptr - ptr);
	return ans;
}

bool nppSortLines(std::vector<std::wstring>& lines, int cmd, size_t fromColumn, size_t toColumn)
{
	bool desc = cmd == IDM_EDIT_SORTLINES_LEXICOGRAPHIC_DESCENDING || cmd == IDM_EDIT_SORTLINES_INTEGER_DESCENDING ||
	            cmd == IDM_EDIT_SORTLINES_DECIMALCOMMA_DESCENDING || cmd == IDM_EDIT_SORTLINES_DECIMALDOT_DESCENDING ||
	            cmd == IDM_EDIT_SORTLINES_LEXICO_CASE_INSENS_DESCENDING || cmd == IDM_EDIT_SORTLINES_LENGTH_DESCENDING;
	std::unique_ptr<ISorter> s;
	switch (cmd)
	{
		case IDM_EDIT_SORTLINES_LEXICOGRAPHIC_ASCENDING:
		case IDM_EDIT_SORTLINES_LEXICOGRAPHIC_DESCENDING:
			s = std::make_unique<LexicographicSorter>(desc, fromColumn, toColumn); break;
		case IDM_EDIT_SORTLINES_LEXICO_CASE_INSENS_ASCENDING:
		case IDM_EDIT_SORTLINES_LEXICO_CASE_INSENS_DESCENDING:
			s = std::make_unique<LexicographicCaseInsensitiveSorter>(desc, fromColumn, toColumn); break;
		case IDM_EDIT_SORTLINES_INTEGER_ASCENDING:
		case IDM_EDIT_SORTLINES_INTEGER_DESCENDING:
			s = std::make_unique<IntegerSorter>(desc, fromColumn, toColumn); break;
		case IDM_EDIT_SORTLINES_DECIMALCOMMA_ASCENDING:
		case IDM_EDIT_SORTLINES_DECIMALCOMMA_DESCENDING:
			s = std::make_unique<DecimalCommaSorter>(desc, fromColumn, toColumn); break;
		case IDM_EDIT_SORTLINES_DECIMALDOT_ASCENDING:
		case IDM_EDIT_SORTLINES_DECIMALDOT_DESCENDING:
			s = std::make_unique<DecimalDotSorter>(desc, fromColumn, toColumn); break;
		case IDM_EDIT_SORTLINES_LENGTH_ASCENDING:
		case IDM_EDIT_SORTLINES_LENGTH_DESCENDING:
			s = std::make_unique<LineLengthSorter>(desc, fromColumn, toColumn); break;
		case IDM_EDIT_SORTLINES_REVERSE_ORDER:
			s = std::make_unique<ReverseSorter>(desc, fromColumn, toColumn); break;
		case IDM_EDIT_SORTLINES_RANDOMLY:
			s = std::make_unique<RandomSorter>(desc, fromColumn, toColumn); break;
		default:
			return false;
	}
	try
	{
		s->sort(lines);
	}
	catch (...)
	{
		return false;
	}
	return true;
}
