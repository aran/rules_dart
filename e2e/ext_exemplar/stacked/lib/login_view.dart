import 'package:stacked_shared/stacked_shared.dart';

@FormView(fields: [
  FormTextField(name: 'email'),
  FormTextField(name: 'password'),
  FormDateField(name: 'birthday'),
  FormDropdownField(name: 'country', items: [
    StaticDropdownItem(title: 'United States', value: 'us'),
    StaticDropdownItem(title: 'Canada', value: 'ca'),
  ]),
])
class LoginView {}
